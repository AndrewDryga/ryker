defmodule Responder.Webhooks.AdapterEndToEndTest do
  use Responder.DataCase, async: true

  import Plug.Conn
  import Plug.Test

  alias Responder.Ingress.Inbox
  alias Responder.Webhooks.{Route, Router}

  @now ~U[2026-09-04 08:00:00Z]
  @secret "a-secret-token-long-enough"
  @hmac_secret "a-webhook-hmac-secret-that-is-long-enough"

  test "one Grafana delivery atomically records every alert without Responder event headers" do
    route = route!(%{kind: :grafana, group_by_labels: ["cluster", "service"]})

    body =
      Jason.encode!(%{
        "status" => "firing",
        "groupKey" => "group:api",
        "commonLabels" => %{"cluster" => "va1", "service" => "api"},
        "alerts" => [
          alert("HighErrors", "errors", "2026-09-04T07:55:00Z"),
          alert("Readiness", "ready", "2026-09-04T07:56:00Z")
        ]
      })

    first = request("grafana", route, body)
    assert first.status == 202
    response = Jason.decode!(first.resp_body)
    assert response["count"] == 2
    assert response["status"] == "recorded"
    assert length(response["input_refs"]) == 2

    entries =
      Enum.map(response["input_refs"], fn ref ->
        assert {:ok, entry} = Inbox.fetch(ref)
        entry
      end)

    assert Enum.map(entries, & &1.revision) == [1, 1]

    assert entries
           |> Enum.map(& &1.content["payload"]["correlation_key"])
           |> Enum.uniq()
           |> length() == 1

    retry = request("grafana", route, body)
    assert retry.status == 202
    assert Jason.decode!(retry.resp_body)["status"] == "duplicate"
  end

  test "Grafana firing and resolved deliveries retain one stable item with ordered revisions" do
    route = route!(%{kind: :grafana, group_by_labels: []})

    firing =
      Jason.encode!(%{
        "status" => "firing",
        "alerts" => [alert("DiskFull", "same", "2026-09-04T07:55:00Z")]
      })

    resolved =
      Jason.encode!(%{
        "status" => "resolved",
        "alerts" => [
          alert("DiskFull", "same", "2026-09-04T07:55:00Z")
          |> Map.put("status", "resolved")
          |> Map.put("endsAt", "2026-09-04T08:05:00Z")
        ]
      })

    first_ref = request("grafana", route, firing) |> response_ref()
    second_ref = request("grafana", route, resolved) |> response_ref()
    assert {:ok, first} = Inbox.fetch(first_ref)
    assert {:ok, second} = Inbox.fetch(second_ref)

    assert first.native_input_id == second.native_input_id
    assert first.revision == 1
    assert second.revision == 2
    assert second.content["payload"]["status"] == "resolved"
  end

  test "a repeated Grafana fingerprint with a new start time opens a distinct alert cycle" do
    route = route!(%{kind: :grafana, group_by_labels: []})

    first =
      Jason.encode!(%{
        "status" => "firing",
        "alerts" => [alert("DiskFull", "reused", "2026-09-04T07:55:00Z")]
      })

    second =
      Jason.encode!(%{
        "status" => "firing",
        "alerts" => [alert("DiskFull", "reused", "2026-09-04T08:10:00Z")]
      })

    first_ref = request("grafana", route, first) |> response_ref()
    second_ref = request("grafana", route, second) |> response_ref()
    assert {:ok, first_entry} = Inbox.fetch(first_ref)
    assert {:ok, second_entry} = Inbox.fetch(second_ref)

    refute first_entry.native_input_id == second_entry.native_input_id
    refute first_entry.event_ref == second_entry.event_ref
    assert first_entry.revision == 1
    assert second_entry.revision == 1
  end

  test "mapped JSON uses configured occurrence and item paths while retaining host routing" do
    route =
      route!(%{
        kind: :mapped_json,
        group_by_labels: ["service"],
        mapping: %{
          event_id: "event.id",
          incident_id: "incident.id",
          labels: "labels",
          status: "incident.state",
          summary: "message",
          title: "incident.title"
        }
      })

    body =
      Jason.encode!(%{
        "event" => %{"id" => "evt-1"},
        "incident" => %{
          "id" => "checkout-7",
          "state" => "triggered",
          "title" => "Checkout latency"
        },
        "labels" => %{"service" => "checkout"},
        "message" => "p99 exceeded",
        "destination" => "attacker-selected"
      })

    ref = request("mapped", route, body) |> response_ref()
    assert {:ok, entry} = Inbox.fetch(ref)
    assert entry.destination_conversation_ref == "slack:T123:C456"
    assert entry.content["payload"]["external_event_id"] == "evt-1"
    assert entry.content["payload"]["status"] == "firing"
    refute Map.has_key?(entry.content["payload"], "destination")
  end

  test "a provider-derived identity remains bound to the exact HMAC-authenticated body" do
    route = route!(%{kind: :grafana, group_by_labels: []}, {:hmac_sha256, @hmac_secret})

    body =
      Jason.encode!(%{
        "status" => "firing",
        "alerts" => [alert("HighErrors", "signed", "2026-09-04T07:55:00Z")]
      })

    signature = hmac_signature(route.name, body)
    assert hmac_request(route, body, signature).status == 202

    tampered = body <> " "
    assert hmac_request(route, tampered, signature).status == 401
  end

  defp request(_name, route, body) do
    conn(:post, "/v1/hooks/#{route.name}", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("authorization", "Bearer #{@secret}")
    |> Router.call(Router.init(now: fn -> @now end, routes: %{route.name => route}))
  end

  defp response_ref(conn) do
    assert conn.status == 202
    Jason.decode!(conn.resp_body)["input_ref"]
  end

  defp alert(name, fingerprint, starts_at) do
    %{
      "annotations" => %{"summary" => name},
      "fingerprint" => fingerprint,
      "labels" => %{"alertname" => name},
      "startsAt" => starts_at,
      "status" => "firing"
    }
  end

  defp hmac_request(route, body, signature) do
    conn(:post, "/v1/hooks/#{route.name}", body)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-responder-timestamp", Integer.to_string(DateTime.to_unix(@now)))
    |> put_req_header("x-responder-signature", signature)
    |> Router.call(Router.init(now: fn -> @now end, routes: %{route.name => route}))
  end

  defp hmac_signature(route_name, body) do
    timestamp = Integer.to_string(DateTime.to_unix(@now))
    signed = Enum.join([timestamp, "/v1/hooks/#{route_name}", "", "", "", "", "", body], "\n")
    digest = :crypto.mac(:hmac, :sha256, @hmac_secret, signed)
    "v1=" <> Base.encode16(digest, case: :lower)
  end

  defp route!(adapter, auth \\ {:bearer, @secret}) do
    assert {:ok, route} =
             Route.new(%{
               adapter: adapter,
               auth: auth,
               destination: %{
                 conversation_ref: "slack:T123:C456",
                 thread_ref: nil,
                 transport: "slack"
               },
               name: "monitoring"
             })

    route
  end
end
