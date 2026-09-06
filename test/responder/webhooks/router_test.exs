defmodule Responder.Webhooks.RouterTest do
  use Responder.DataCase, async: true

  # A suite-owned workspace keeps conversation locks out of other async fixtures.

  @moduletag isolation: "REPEATABLE READ"

  import Plug.Conn
  import Plug.Test

  alias Responder.Admission
  alias Responder.Admission.Decision
  alias Responder.Ingress.Inbox
  alias Responder.Webhooks.{Route, Router}

  @now ~U[2026-08-27 12:00:00.000000Z]
  @secret "a-secret-token-long-enough"

  test "durably admits arbitrary JSON and returns before model work starts" do
    body = Jason.encode!(%{"new_vendor" => %{"state" => "firing"}})

    conn =
      request(body,
        authorization: "Bearer #{@secret}",
        event_id: "evt-123",
        event_type: "vendor.changed"
      )

    assert conn.status == 202
    response = Jason.decode!(conn.resp_body)
    assert response["status"] == "recorded"
    assert {:ok, entry} = Inbox.fetch(response["input_ref"])
    assert entry.status == :pending
    assert entry.source_kind == "webhook"
    assert entry.content["payload"] == %{"new_vendor" => %{"state" => "firing"}}
    assert entry.destination_conversation_ref == "slack:TWEBHOOKROUTER:C456"
    assert entry.destination_thread_ref == nil
    assert entry.work_policy == "webhook-read-only"
    assert entry.work_policy_digest == String.duplicate("a", 64)
    assert entry.repository_ref == "owner/service"

    assert {:ok, context} =
             Admission.context(response["input_ref"],
               candidate_limit: 8,
               continuation_window: 1_800,
               history_window: 86_400,
               now: @now
             )

    assert {:ok, decision} =
             Decision.parse(%{
               "action" => "start_episode",
               "episode_ref" => nil,
               "reaction" => nil,
               "relation" => "unrelated",
               "reason" => "This unfamiliar event needs investigation.",
               "work_class" => "standard"
             })

    assert {:ok, result} = Admission.commit(context, decision, "webhook-decision:evt-123")
    assert result.episode.destination_conversation_ref == "slack:TWEBHOOKROUTER:C456"
    assert result.episode.destination_thread_ref == nil
  end

  test "retries return the original durable receipt and changed reuse conflicts" do
    headers = [authorization: "Bearer #{@secret}", event_id: "evt-retry"]
    first = request(~s({"value":1}), Keyword.put(headers, :now, @now))

    retry =
      request(~s({"value":1}), Keyword.put(headers, :now, DateTime.add(@now, 1, :second)))

    changed = request(~s({"value":2}), headers)

    assert first.status == 202
    assert retry.status == 202
    assert Jason.decode!(retry.resp_body)["status"] == "duplicate"

    assert Jason.decode!(first.resp_body)["input_ref"] ==
             Jason.decode!(retry.resp_body)["input_ref"]

    assert changed.status == 409
    assert Jason.decode!(changed.resp_body)["error"] == "event_conflict"

    explicit_time = DateTime.to_iso8601(@now)

    assert request(~s({"value":1}),
             authorization: "Bearer #{@secret}",
             event_id: "evt-explicit-time",
             occurred_at: explicit_time
           ).status == 202

    assert request(~s({"value":1}),
             authorization: "Bearer #{@secret}",
             event_id: "evt-explicit-time",
             occurred_at: DateTime.add(@now, 1, :second) |> DateTime.to_iso8601()
           ).status == 409
  end

  test "separate webhook occurrences can revise one stable source item" do
    first =
      request(~s({"state":"firing"}),
        authorization: "Bearer #{@secret}",
        event_id: "evt-lifecycle-firing",
        item_id: "incident-42",
        revision: "1"
      )

    assert first.status == 202
    assert {:ok, first_entry} = Inbox.fetch(Jason.decode!(first.resp_body)["input_ref"])

    assert {:ok, first_context} =
             Admission.context(Inbox.ref(first_entry),
               candidate_limit: 8,
               continuation_window: 1_800,
               history_window: 86_400,
               now: @now
             )

    start = decision!(:start_episode, nil, :unrelated)
    assert {:ok, started} = Admission.commit(first_context, start, "webhook-lifecycle-start")

    second =
      request(~s({"state":"resolved"}),
        authorization: "Bearer #{@secret}",
        event_id: "evt-lifecycle-resolved",
        item_id: "incident-42",
        revision: "2"
      )

    assert second.status == 202
    assert {:ok, second_entry} = Inbox.fetch(Jason.decode!(second.resp_body)["input_ref"])
    assert second_entry.native_input_id == first_entry.native_input_id
    refute second_entry.dedupe_key == first_entry.dedupe_key

    assert {:ok, second_context} =
             Admission.context(Inbox.ref(second_entry),
               candidate_limit: 8,
               continuation_window: 1_800,
               history_window: 86_400,
               now: DateTime.add(@now, 1, :second)
             )

    owner = Enum.find(second_context.candidates, &(&1.episode.id == started.episode.id))
    assert owner.allowed_relations == [:same_work, :history_only]

    continue = decision!(:continue_episode, owner.ref, :same_work)

    assert {:ok, continued} =
             Admission.commit(second_context, continue, "webhook-lifecycle-update")

    assert continued.episode.id == started.episode.id
    assert continued.episode.input_revisions[first_entry.native_input_id] == 2
  end

  test "rejects bad auth, missing identity, malformed JSON, wrong media type, and oversized bodies" do
    assert request("{}", event_id: "evt-no-auth").status == 401
    assert request("{}", authorization: "Bearer #{@secret}").status == 400

    assert request("{",
             authorization: "Bearer #{@secret}",
             event_id: "evt-bad-json"
           ).status == 400

    assert request("{}",
             authorization: "Bearer #{@secret}",
             content_type: "text/plain",
             event_id: "evt-text"
           ).status == 415

    assert request(Jason.encode!(%{"value" => String.duplicate("x", 40_001)}),
             authorization: "Bearer #{@secret}",
             event_id: "evt-large"
           ).status == 413
  end

  test "validates signed requests without trusting a sender-selected route or time" do
    secret = String.duplicate("h", 32)
    route = route!({:hmac_sha256, secret})
    body = ~s(["anything",42])
    timestamp = Integer.to_string(DateTime.to_unix(@now))
    signature = hmac_signature(secret, body, timestamp, "evt-hmac")

    conn =
      request(body,
        event_id: "evt-hmac",
        route: route,
        signature: signature,
        timestamp: timestamp
      )

    assert conn.status == 202

    stale =
      request(body,
        event_id: "evt-hmac-stale",
        route: route,
        signature: signature,
        timestamp: Integer.to_string(DateTime.to_unix(@now) - 301)
      )

    assert stale.status == 401

    tampered_identity =
      request(body,
        event_id: "evt-hmac-replayed-as-new",
        route: route,
        signature: signature,
        timestamp: timestamp
      )

    assert tampered_identity.status == 401

    unsigned =
      request(body,
        event_id: "evt-hmac-unsigned",
        route: route,
        timestamp: timestamp
      )

    assert unsigned.status == 401

    signed_metadata = [
      event_type: "vendor.changed",
      item_id: "vendor-item-42",
      occurred_at: DateTime.to_iso8601(@now),
      revision: "2"
    ]

    metadata_signature =
      hmac_signature(secret, body, timestamp, "evt-hmac-metadata", signed_metadata)

    assert request(
             body,
             signed_metadata ++
               [
                 event_id: "evt-hmac-metadata",
                 route: route,
                 signature: metadata_signature,
                 timestamp: timestamp
               ]
           ).status == 202

    assert request(
             body,
             Keyword.put(signed_metadata, :item_id, "vendor-item-tampered") ++
               [
                 event_id: "evt-hmac-metadata",
                 route: route,
                 signature: metadata_signature,
                 timestamp: timestamp
               ]
           ).status == 401

    assert request(
             body,
             signed_metadata ++
               [
                 event_id: "evt-hmac-metadata-tampered",
                 route: route,
                 signature: metadata_signature,
                 timestamp: timestamp
               ]
           ).status == 401

    assert request(body,
             route: route,
             signature: signature,
             timestamp: timestamp
           ).status == 401
  end

  test "unknown routes and methods reveal no configured integration details" do
    conn = conn(:post, "/v1/hooks/missing", "{}") |> Router.call(router_options())
    assert conn.status == 404

    conn = conn(:get, "/v1/hooks/universal") |> Router.call(router_options())
    assert conn.status == 404
  end

  test "accepts JSON suffix media types and rejects malformed event metadata" do
    accepted =
      request("{}",
        authorization: "Bearer #{@secret}",
        content_type: "application/cloudevents+json; charset=utf-8",
        event_id: "evt-cloud-event"
      )

    assert accepted.status == 202

    invalid_time =
      request("{}",
        authorization: "Bearer #{@secret}",
        event_id: "evt-invalid-time",
        occurred_at: "tomorrow"
      )

    assert invalid_time.status == 400

    invalid_revision =
      request("{}",
        authorization: "Bearer #{@secret}",
        event_id: "evt-invalid-revision",
        revision: "0"
      )

    assert invalid_revision.status == 400
  end

  defp request(body, options) do
    route = Keyword.get(options, :route, route!({:bearer, @secret}))
    content_type = Keyword.get(options, :content_type, "application/json")

    conn =
      conn(:post, "/v1/hooks/universal", body)
      |> put_req_header("content-type", content_type)
      |> maybe_header("authorization", options[:authorization])
      |> maybe_header("x-responder-event-id", options[:event_id])
      |> maybe_header("x-responder-item-id", options[:item_id])
      |> maybe_header("x-responder-event-type", options[:event_type])
      |> maybe_header("x-responder-occurred-at", options[:occurred_at])
      |> maybe_header("x-responder-revision", options[:revision])
      |> maybe_header("x-responder-signature", options[:signature])
      |> maybe_header("x-responder-timestamp", options[:timestamp])

    Router.call(conn, router_options(route, Keyword.get(options, :now, @now)))
  end

  defp maybe_header(conn, _name, nil), do: conn
  defp maybe_header(conn, name, value), do: put_req_header(conn, name, value)

  defp router_options(route \\ route!({:bearer, @secret}), now \\ @now) do
    Router.init(now: fn -> now end, routes: %{"universal" => route})
  end

  defp hmac_signature(secret, body, timestamp, event_id, metadata \\ []) do
    signed =
      [
        timestamp,
        "/v1/hooks/universal",
        event_id,
        Keyword.get(metadata, :item_id, ""),
        Keyword.get(metadata, :event_type, ""),
        Keyword.get(metadata, :occurred_at, ""),
        Keyword.get(metadata, :revision, ""),
        body
      ]
      |> Enum.join("\n")

    "v1=" <>
      Base.encode16(:crypto.mac(:hmac, :sha256, secret, signed), case: :lower)
  end

  defp route!(auth) do
    assert {:ok, route} =
             Route.new(%{
               auth: auth,
               destination: %{
                 conversation_ref: "slack:TWEBHOOKROUTER:C456",
                 thread_ref: nil,
                 transport: "slack"
               },
               max_body_bytes: 40_000,
               max_clock_skew_seconds: 300,
               name: "universal",
               work_profile: %{
                 policy: "webhook-read-only",
                 policy_digest: String.duplicate("a", 64),
                 repository_ref: "owner/service"
               }
             })

    route
  end

  defp decision!(action, episode_ref, relation) do
    assert {:ok, decision} =
             Decision.parse(%{
               "action" => Atom.to_string(action),
               "episode_ref" => episode_ref,
               "reaction" => nil,
               "relation" => Atom.to_string(relation),
               "reason" => "This webhook occurrence belongs to the supplied lifecycle.",
               "work_class" => if(action == :reply, do: "conversational", else: "standard")
             })

    decision
  end
end
