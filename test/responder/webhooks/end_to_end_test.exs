defmodule Responder.Webhooks.EndToEndTest do
  use Responder.DataCase, async: true

  @moduletag isolation: "REPEATABLE READ"

  import Plug.Conn
  import Plug.Test

  alias Responder.Admission.Dispatcher
  alias Responder.Episodes
  alias Responder.TestSupport.FakeCoopAPI
  alias Responder.Webhooks.{Route, Router}

  @now ~U[2026-08-27 12:00:00.000000Z]
  @secret "a-secret-token-long-enough"

  test "an unknown authenticated webhook reaches one model turn and one durable episode" do
    body = Jason.encode!(%{"vendor_we_have_never_seen" => %{"severity" => 17, "state" => "odd"}})

    first = post(body, "vendor-occurrence-123")
    retry = post(body, "vendor-occurrence-123")

    assert first.status == 202
    assert retry.status == 202
    assert Jason.decode!(retry.resp_body)["status"] == "duplicate"

    {:ok, fake} = FakeCoopAPI.start_link([decision("start_episode")])

    assert {:ok, {:decided, execution}} = Dispatcher.run_once(dispatcher_options(fake))
    assert execution.result.entry.source_kind == :webhook
    assert execution.result.entry.decision_action == :start_episode
    assert execution.result.episode.destination_conversation_ref == "slack:T123:C456"

    assert [event] = Episodes.list_events(execution.result.episode.key)
    assert event.payload["payload"]["content"]["payload"] == Jason.decode!(body)

    assert {:ok, :idle} = Dispatcher.run_once(dispatcher_options(fake))
    assert FakeCoopAPI.state(fake).submit_count == 1
  end

  defp post(body, event_id) do
    conn(:post, "/v1/hooks/universal", body)
    |> put_req_header("authorization", "Bearer #{@secret}")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-responder-event-id", event_id)
    |> put_req_header("x-responder-event-type", "new.vendor.event")
    |> Router.call(router_options())
  end

  defp router_options do
    assert {:ok, route} =
             Route.new(%{
               auth: {:bearer, @secret},
               destination: %{
                 conversation_ref: "slack:T123:C456",
                 thread_ref: nil,
                 transport: "slack"
               },
               name: "universal"
             })

    Router.init(now: fn -> @now end, routes: %{"universal" => route})
  end

  defp dispatcher_options(fake) do
    [
      executor_options: [
        api: FakeCoopAPI,
        client: fake,
        max_polls: 10,
        now: fn -> @now end,
        policy: "admission-read-only",
        poll_interval_ms: 0,
        sleep: fn _milliseconds -> :ok end
      ],
      lease_seconds: 300,
      now: fn -> @now end,
      retry_base_ms: 1_000,
      retry_max_ms: 60_000,
      worker_ref: "webhook-e2e:test"
    ]
  end

  defp decision(action) do
    Jason.encode!(%{
      "action" => action,
      "episode_ref" => nil,
      "reaction" => nil,
      "relation" => "unrelated",
      "reason" => "This unknown event needs a new episode so Responder can inspect it."
    })
  end
end
