defmodule Ryker.Webhooks.TransformsTest do
  use ExUnit.Case, async: true

  alias Ryker.Webhooks.{Route, Transforms}

  @now ~U[2026-09-04 08:00:00Z]

  test "Grafana alerts keep cycle identity and share deterministic group correlation" do
    route = grafana_route!()

    payload = %{
      "status" => "firing",
      "groupKey" => ~s({}:{cluster="va1",service="api"}),
      "externalURL" => "https://grafana.example/alerting/list",
      "commonLabels" => %{
        "cluster" => "va1",
        "service" => "api",
        "severity" => "critical"
      },
      "commonAnnotations" => %{"description" => "shared description"},
      "alerts" => [
        %{
          "status" => "firing",
          "labels" => %{"alertname" => "HighErrors"},
          "annotations" => %{"summary" => "API error rate"},
          "startsAt" => "2026-09-04T07:55:00Z",
          "fingerprint" => "abc",
          "panelURL" => "https://grafana.example/panel/1"
        },
        %{
          "status" => "active",
          "labels" => %{"alertname" => "Readiness"},
          "annotations" => %{"summary" => "API readiness"},
          "startsAt" => "2026-09-04T07:56:00Z",
          "fingerprint" => "def"
        }
      ]
    }

    assert {:ok, %{inputs: [first, second], revision_ties: :receipt_order_unbounded}} =
             Transforms.normalize(route, payload, metadata())

    assert first.native_input_id != second.native_input_id

    assert first.content["payload"]["correlation_key"] ==
             second.content["payload"]["correlation_key"]

    assert first.content["payload"] == %{
             "adapter" => "grafana",
             "annotations" => %{
               "description" => "shared description",
               "summary" => "API error rate"
             },
             "correlation_key" => first.content["payload"]["correlation_key"],
             "ends_at" => nil,
             "labels" => %{
               "alertname" => "HighErrors",
               "cluster" => "va1",
               "service" => "api",
               "severity" => "critical"
             },
             "severity" => "critical",
             "source_fingerprint" => "abc",
             "source_incident_id" => ~s({}:{cluster="va1",service="api"}),
             "source_url" => "https://grafana.example/panel/1",
             "starts_at" => "2026-09-04T07:55:00Z",
             "status" => "firing",
             "summary" => "shared description",
             "title" => "API error rate"
           }

    assert first.content["event_type"] == "grafana.alert.firing"
    assert first.occurred_at == ~U[2026-09-04 07:55:00.000000Z]
    assert first.occurred_at_source == :source
  end

  test "a Grafana resolution retains the exact alert-cycle item and advances occurrence identity" do
    route = grafana_route!()
    firing = grafana_payload("firing", nil)
    resolved = grafana_payload("resolved", "2026-09-04T08:05:00Z")

    assert {:ok, %{inputs: [first]}} = Transforms.normalize(route, firing, metadata())
    assert {:ok, %{inputs: [second]}} = Transforms.normalize(route, resolved, metadata())

    assert first.native_input_id == second.native_input_id
    refute first.event_ref == second.event_ref
    assert second.content["payload"]["status"] == "resolved"
    assert second.content["event_type"] == "grafana.alert.resolved"
    assert second.occurred_at == ~U[2026-09-04 08:05:00.000000Z]
  end

  test "mapped JSON exposes only bounded configured fields and cannot redirect ingress" do
    route = mapped_route!()

    payload = %{
      "event" => %{"id" => "evt-1"},
      "incident" => %{
        "id" => "upstream-7",
        "state" => "open",
        "title" => "Checkout unavailable",
        "severity" => "p1",
        "url" => "https://status.example/i/7",
        "started_at" => "2026-09-04T07:58:00Z"
      },
      "labels" => %{"service" => "checkout", "affected" => 12},
      "message" => "timeouts",
      "destination" => %{"transport" => "attacker", "conversation_ref" => "crossed"},
      "ignored" => %{"secret" => "not model input"}
    }

    assert {:ok, %{inputs: [input], revision_ties: :receipt_order_unbounded}} =
             Transforms.normalize(route, payload, metadata())

    assert input.actor == %{kind: :system, ref: "monitoring"}
    assert input.destination == route.destination
    assert input.content["event_type"] == "mapped_json.alert.firing"

    assert input.content["payload"] == %{
             "adapter" => "mapped_json",
             "annotations" => nil,
             "correlation_key" => input.content["payload"]["correlation_key"],
             "ends_at" => nil,
             "external_event_id" => "evt-1",
             "labels" => %{"affected" => "12", "service" => "checkout"},
             "severity" => "p1",
             "source_incident_id" => "upstream-7",
             "source_url" => "https://status.example/i/7",
             "starts_at" => "2026-09-04T07:58:00Z",
             "status" => "firing",
             "summary" => "timeouts",
             "title" => "Checkout unavailable"
           }

    refute input.content["payload"] |> Map.has_key?("ignored")
    assert input.occurred_at == ~U[2026-09-04 07:58:00.000000Z]
  end

  test "mapped route configuration rejects array-index paths" do
    assert {:error, {:invalid_webhook_route, :adapter}} =
             route_attributes(%{
               kind: :mapped_json,
               mapping: %{event_id: "array.0.id", status: "state", title: "title"}
             })
             |> Route.new()
  end

  test "Grafana requires a nonempty alert batch with a supported lifecycle status" do
    assert {:error, {:invalid_webhook_transform, :alerts}} =
             Transforms.normalize(grafana_route!(), %{"alerts" => []}, metadata())

    assert {:error, {:invalid_webhook_transform, :status}} =
             Transforms.normalize(
               grafana_route!(),
               grafana_payload("indeterminate", nil),
               metadata()
             )

    assert {:error, {:invalid_webhook_transform, :payload}} =
             Transforms.normalize(grafana_route!(), "not-an-object", metadata())

    assert {:error, {:invalid_webhook_transform, :alerts}} =
             Transforms.normalize(grafana_route!(), nil, metadata())
  end

  test "mapped JSON retains only safe HTTP source links" do
    unsafe = put_in(mapped_payload(), ["incident", "url"], "file:///etc/passwd")

    assert {:error, {:invalid_webhook_transform, :source_url}} =
             Transforms.normalize(mapped_route!(), unsafe, metadata())
  end

  test "specialized transforms accept only the exact typed ingress metadata shape" do
    assert {:error, {:invalid_webhook_transform, :metadata}} =
             Transforms.normalize(
               grafana_route!(),
               grafana_payload("firing", nil),
               Map.put(metadata(), :unexpected, true)
             )

    assert {:error, {:invalid_webhook_transform, :metadata}} =
             Transforms.normalize(grafana_route!(), grafana_payload("firing", nil), nil)

    assert {:error, {:invalid_webhook_transform, :metadata}} =
             Transforms.normalize(
               mapped_route!(),
               mapped_payload(),
               metadata() |> Map.to_list() |> Kernel.++(event_id: "duplicate")
             )

    identified_metadata = %{metadata() | event_id: "evt-provider", item_id: "item-provider"}

    assert {:ok, %{inputs: [_input]}} =
             Transforms.normalize(
               grafana_route!(),
               grafana_payload("firing", nil),
               identified_metadata
             )

    for invalid <- [%{metadata() | event_id: 123}, %{metadata() | occurred_at: nil}] do
      assert {:error, {:invalid_webhook_transform, :metadata}} =
               Transforms.normalize(
                 grafana_route!(),
                 grafana_payload("firing", nil),
                 invalid
               )
    end
  end

  test "Grafana rejects non-string correlation and label fields" do
    malformed_group = Map.put(grafana_payload("firing", nil), "groupKey", %{"bad" => true})

    assert {:error, {:invalid_webhook_transform, :group_key}} =
             Transforms.normalize(grafana_route!(), malformed_group, metadata())

    assert {:error, {:invalid_webhook_transform, :labels}} =
             Transforms.normalize(
               grafana_route!(),
               Map.put(grafana_payload("firing", nil), "commonLabels", %{"bad" => 1}),
               metadata()
             )

    assert {:error, {:invalid_webhook_transform, :labels}} =
             Transforms.normalize(
               grafana_route!(),
               Map.put(grafana_payload("firing", nil), "commonLabels", []),
               metadata()
             )
  end

  test "mapped JSON label objects require string keys and scalar values" do
    assert {:error, {:invalid_webhook_transform, :labels}} =
             Transforms.normalize(
               mapped_route!(),
               Map.put(mapped_payload(), "labels", %{1 => "invalid-key"}),
               metadata()
             )
  end

  test "Grafana treats an absent or blank group key as optional" do
    for group_key <- [nil, " "] do
      assert {:ok, %{inputs: [_input]}} =
               Transforms.normalize(
                 grafana_route!(),
                 Map.put(grafana_payload("firing", nil), "groupKey", group_key),
                 metadata()
               )
    end
  end

  test "Grafana derives a stable fallback identity when optional provider IDs are absent" do
    payload =
      grafana_payload("firing", nil)
      |> Map.delete("groupKey")
      |> update_in(["alerts", Access.at(0)], &Map.delete(&1, "fingerprint"))

    assert {:ok, %{inputs: [input]}} = Transforms.normalize(grafana_route!(), payload, metadata())
    assert input.content["payload"]["source_incident_id"] == nil
    assert byte_size(input.content["payload"]["source_fingerprint"]) == 64
  end

  test "the universal transform preserves explicit source identity without provider interpretation" do
    assert {:ok, route} = route_attributes(%{kind: :universal}) |> Route.new()
    metadata = %{metadata() | event_id: "evt-universal", item_id: "item-universal"}
    payload = %{"provider_specific" => [1, 2, 3]}

    assert {:ok, %{inputs: [input], revision_ties: :exact}} =
             Transforms.normalize(route, payload, metadata)

    assert input.content["payload"] == payload
    assert input.event_ref == "evt-universal"
  end

  test "mapped JSON normalizes configured scalar types and exact source revisions" do
    route = mapped_route!(%{item_id: "incident.item", revision: "event.revision"})

    payload = %{
      "event" => %{"id" => 42, "revision" => "2"},
      "annotations" => nil,
      "incident" => %{
        "ended_at" => nil,
        "severity" => 1.5,
        "started_at" => "",
        "state" => "ok",
        "title" => true
      },
      "labels" => %{"service" => "checkout"},
      "message" => nil
    }

    assert {:ok, %{inputs: [input], revision_ties: :exact}} =
             Transforms.normalize(route, payload, metadata())

    assert input.revision == 2
    assert input.content["payload"]["external_event_id"] == "42"
    assert input.content["payload"]["severity"] == "1.5"
    assert input.content["payload"]["status"] == "resolved"
    assert input.content["payload"]["title"] == "true"
    assert input.content["payload"]["starts_at"] == nil
    assert input.content["payload"]["ends_at"] == nil
  end

  test "mapped JSON rejects oversized values that participate in source identity" do
    oversized = String.duplicate("a", 1_025)

    for {mapping, path, field} <- [
          {%{}, ["event", "id"], :event_id},
          {%{item_id: "incident.item"}, ["incident", "item"], :item_id},
          {%{incident_id: "incident.id"}, ["incident", "id"], :incident_id}
        ] do
      assert {:error, {:invalid_webhook_transform, ^field}} =
               Transforms.normalize(
                 mapped_route!(mapping),
                 put_in(mapped_payload(), path, oversized),
                 metadata()
               )
    end
  end

  test "Grafana rejects oversized fingerprint and group identities" do
    fingerprint_payload =
      put_in(
        grafana_payload("firing", nil),
        ["alerts", Access.at(0), "fingerprint"],
        String.duplicate("f", 501)
      )

    assert {:error, {:invalid_webhook_transform, :fingerprint}} =
             Transforms.normalize(grafana_route!(), fingerprint_payload, metadata())

    group_payload =
      Map.put(grafana_payload("firing", nil), "groupKey", String.duplicate("g", 1_025))

    assert {:error, {:invalid_webhook_transform, :group_key}} =
             Transforms.normalize(grafana_route!(), group_payload, metadata())
  end

  test "bounded provider display fields remain valid UTF-8 within byte limits" do
    long_title = String.duplicate("🚨", 200)
    long_label_key = String.duplicate("🛠", 40)
    long_label_value = String.duplicate("🔥", 300)

    payload =
      grafana_payload("firing", nil)
      |> put_in(["alerts", Access.at(0), "annotations", "summary"], long_title)
      |> put_in(["alerts", Access.at(0), "labels", long_label_key], long_label_value)

    assert {:ok, %{inputs: [input]}} =
             Transforms.normalize(grafana_route!(), payload, metadata())

    title = input.content["payload"]["title"]

    {label_key, label_value} =
      Enum.find(input.content["payload"]["labels"], fn {key, _value} ->
        String.starts_with?(key, "🛠")
      end)

    assert String.valid?(title) and byte_size(title) <= 500
    assert String.valid?(label_key) and byte_size(label_key) <= 128
    assert String.valid?(label_value) and byte_size(label_value) <= 1_000
  end

  test "an unknown transform route fails closed" do
    assert {:error, {:invalid_webhook_transform, :route}} =
             Transforms.normalize(:not_a_route, %{}, metadata())
  end

  test "mapped JSON requires a nonblank external event identity" do
    assert {:error, {:invalid_webhook_transform, :event_id}} =
             Transforms.normalize(mapped_route!(), %{}, metadata())

    assert {:error, {:invalid_webhook_transform, :event_id}} =
             Transforms.normalize(
               mapped_route!(),
               put_in(mapped_payload(), ["event", "id"], " "),
               metadata()
             )
  end

  test "mapped JSON object fields reject arrays and nested values" do
    assert {:error, {:invalid_webhook_transform, :labels}} =
             Transforms.normalize(
               mapped_route!(),
               Map.put(mapped_payload(), "labels", ["not", "an", "object"]),
               metadata()
             )

    assert {:error, {:invalid_webhook_transform, :labels}} =
             Transforms.normalize(
               mapped_route!(),
               Map.put(mapped_payload(), "labels", %{"nested" => %{}}),
               metadata()
             )
  end

  test "mapped JSON occurrence times must be ISO-8601 strings" do
    for value <- ["tomorrow", 123] do
      assert {:error, {:invalid_webhook_transform, :starts_at}} =
               Transforms.normalize(
                 mapped_route!(),
                 put_in(mapped_payload(), ["incident", "started_at"], value),
                 metadata()
               )
    end
  end

  test "mapped JSON uses exact positive source revisions when supplied" do
    for value <- [0, "two"] do
      assert {:error, {:invalid_webhook_transform, :revision}} =
               Transforms.normalize(
                 mapped_route!(%{revision: "event.revision"}),
                 put_in(mapped_payload(), ["event", "revision"], value),
                 metadata()
               )
    end

    assert {:ok, %{inputs: [input], revision_ties: :exact}} =
             Transforms.normalize(
               mapped_route!(%{revision: "event.revision"}),
               put_in(mapped_payload(), ["event", "revision"], 3),
               metadata()
             )

    assert input.revision == 3
  end

  test "mapped JSON assigns durable receipt order when source revision is absent" do
    for payload <- [mapped_payload(), put_in(mapped_payload(), ["event", "revision"], nil)] do
      assert {:ok, %{revision_ties: :receipt_order_unbounded}} =
               Transforms.normalize(
                 mapped_route!(%{revision: "event.revision"}),
                 payload,
                 metadata()
               )
    end
  end

  test "Grafana requires a title from its documented fallback chain" do
    missing_title =
      grafana_payload("firing", nil)
      |> Map.delete("title")
      |> put_in(["alerts", Access.at(0), "annotations"], %{})
      |> put_in(["alerts", Access.at(0), "labels"], %{})

    assert {:error, {:invalid_webhook_transform, :title}} =
             Transforms.normalize(grafana_route!(), missing_title, metadata())
  end

  defp grafana_payload(status, ends_at) do
    %{
      "status" => status,
      "groupKey" => "group:disk",
      "alerts" => [
        %{
          "status" => status,
          "labels" => %{"alertname" => "DiskFull"},
          "annotations" => %{"summary" => "Disk full"},
          "startsAt" => "2026-09-04T07:55:00Z",
          "endsAt" => ends_at,
          "fingerprint" => "same"
        }
      ]
    }
  end

  defp mapped_payload do
    %{
      "event" => %{"id" => "evt-1"},
      "incident" => %{
        "id" => "upstream-7",
        "state" => "firing",
        "title" => "Checkout unavailable",
        "url" => "https://status.example/i/7"
      }
    }
  end

  defp grafana_route! do
    assert {:ok, route} =
             route_attributes(%{kind: :grafana, group_by_labels: ["cluster", "service"]})
             |> Route.new()

    route
  end

  defp mapped_route!(mapping_overrides \\ %{}) do
    mapping =
      Map.merge(
        %{
          annotations: "annotations",
          ends_at: "incident.ended_at",
          event_id: "event.id",
          incident_id: "incident.id",
          labels: "labels",
          severity: "incident.severity",
          source_url: "incident.url",
          starts_at: "incident.started_at",
          status: "incident.state",
          summary: "message",
          title: "incident.title"
        },
        mapping_overrides
      )

    assert {:ok, route} =
             route_attributes(%{
               kind: :mapped_json,
               group_by_labels: ["service"],
               mapping: mapping
             })
             |> Route.new()

    route
  end

  defp route_attributes(adapter) do
    %{
      adapter: adapter,
      auth: {:bearer, "a-secret-token-long-enough"},
      destination: %{
        conversation_ref: "slack:T123:C456",
        thread_ref: nil,
        transport: "slack"
      },
      name: "monitoring"
    }
  end

  defp metadata do
    %{
      event_id: nil,
      event_type: nil,
      item_id: nil,
      occurred_at: @now,
      occurred_at_source: :ingress,
      revision: 1
    }
  end
end
