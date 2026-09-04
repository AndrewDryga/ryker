defmodule Responder.Work.ActivityTest do
  use Responder.DataCase, async: false

  defmodule OversizedAPI do
    def list_events(_client, _session_id, _cursor, _limit),
      do: {:ok, List.duplicate(%{}, 1_001)}
  end

  defmodule ErrorAPI do
    def list_events(_client, _session_id, _cursor, _limit), do: {:error, :unavailable}
  end

  defmodule EmptyAPI do
    def list_events(_client, _session_id, _cursor, _limit), do: {:ok, []}
  end

  defmodule PagedAPI do
    def list_events(pages, _session_id, cursor, _limit), do: {:ok, Map.fetch!(pages, cursor)}
  end

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Work.{Activity, ActivitySyncWorker, Custody}

  @now ~U[2026-09-04 12:00:00.000000Z]

  test "a replayed Coop page advances one durable cursor without duplicating activity" do
    episode_id = Ecto.UUID.generate()
    episode_key = "activity:#{episode_id}"

    assert {:ok, started} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: episode_key,
                 native_input_id: "activity-input:#{episode_id}",
                 occurred_at: @now,
                 turn_ref: "activity-turn:#{episode_id}"
               })
             )

    assert {:ok, session} =
             Custody.pin_episode(started.episode.id, "policy:activity", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("activity-recorder", 60, :work)

    assert {:ok, session} =
             Custody.bind_session(
               started.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               session.create_generation,
               "remote:#{session.id}"
             )

    events = [
      event(session, 1, "session.created", %{}) |> Map.delete("turn_id"),
      event(session, 2, "model.thought", %{"text" => "Checking the runtime state."}),
      event(session, 3, "tool.started", %{
        "input" => %{"action_id" => "nomad.job_status", "args" => %{"job" => "responder"}},
        "kind" => "mcp",
        "title" => "mcp.emisar.run_action",
        "tool_call_id" => "tool-1"
      }),
      event(session, 4, "tool.completed", %{
        "kind" => "mcp",
        "status" => "completed",
        "title" => "mcp.emisar.run_action",
        "tool_call_id" => "tool-1"
      })
    ]

    assert {:ok, %{cursor: 4, inserted: 3}} = Activity.ingest(session.id, events)
    assert {:ok, %{cursor: 4, inserted: 0}} = Activity.ingest(session.id, events)

    assert [thought, started_tool, completed_tool] = Activity.list_for_episode(episode_id)
    assert thought.kind == "model.thought"
    assert thought.payload == %{}
    assert started_tool.kind == "tool.started"

    assert started_tool.payload == %{
             "input" => %{"operation" => "nomad.job_status"},
             "tool_call_id" => "tool-1"
           }

    assert completed_tool.kind == "tool.completed"
    assert completed_tool.payload == %{"status" => "completed", "tool_call_id" => "tool-1"}

    changed_identity = events |> Enum.at(1) |> Map.put("id", "event-2-changed")

    assert {:error, {:coop_activity_replay_conflict, 2}} =
             Activity.ingest(session.id, [changed_identity])

    public_events = [
      event(session, 5, "model.plan", %{
        "entries" => [%{"text" => "private plan text"}],
        "private" => "must not survive"
      }),
      event(session, 6, "permission.decided", %{
        "option_kind" => "allow_once",
        "outcome" => "allowed",
        "private" => "must not survive",
        "tool_call_id" => "tool-2"
      }),
      event(session, 7, "activity.elided", %{"dropped" => 3, "private" => "must not survive"}),
      event(session, 8, "provider.backoff", %{
        "attempt" => 2,
        "private" => "must not survive",
        "retry_after_seconds" => 5,
        "target" => "standard"
      }),
      event(session, 9, "provider.alive", %{
        "bytes" => 2_048,
        "frames" => 4,
        "private" => "must not survive"
      }),
      event(session, 10, "model.plan", %{}),
      event(session, 11, "provider.backoff", %{
        "all_limited_until" => "not-a-time",
        "attempt" => "two",
        "next_target" => 7,
        "reset_at" => "2026-09-04T12:05:00Z"
      }),
      event(session, 12, "tool.started", %{
        "input" => %{"arguments" => %{"action_id" => "nomad.allocations"}},
        "tool_call_id" => "tool-3"
      })
    ]

    assert {:ok, %{cursor: 12, inserted: 8}} = Activity.ingest(session.id, public_events)

    assert [plan, permission, elided, backoff, alive, empty_plan, filtered_backoff, tool] =
             Activity.list_for_episode(episode_id) |> Enum.take(-8)

    assert plan.payload == %{"step_count" => 1}

    assert permission.payload == %{
             "option_kind" => "allow_once",
             "outcome" => "allowed",
             "tool_call_id" => "tool-2"
           }

    assert elided.payload == %{"dropped" => 3}

    assert backoff.payload == %{
             "attempt" => 2,
             "retry_after_seconds" => 5,
             "target" => "standard"
           }

    assert alive.payload == %{"bytes" => 2_048, "frames" => 4}
    assert empty_plan.payload == %{"step_count" => 0}
    assert filtered_backoff.payload == %{"reset_at" => "2026-09-04T12:05:00Z"}
    assert tool.payload["input"] == %{"operation" => "nomad.allocations"}

    assert {:error, {:coop_activity_cursor_gap, 13, 14}} =
             Activity.ingest(session.id, [event(session, 14, "model.plan", %{"entries" => []})])

    assert Activity.ingest(session.id, [event(session, 13, "model.plan", %{"step_count" => 33})]) ==
             {:error, {:invalid_coop_activity, :step_count}}

    assert Activity.ingest(session.id, [event(session, 13, "activity.elided", %{"dropped" => -1})]) ==
             {:error, {:invalid_coop_activity, :dropped}}

    assert Activity.ingest(session.id, [
             event(session, 13, "tool.started", %{"tool_call_id" => 7})
           ]) ==
             {:error, {:invalid_coop_activity, :tool_call_id}}

    assert Activity.sync(%{session | coop_session_id: nil}, OversizedAPI, :client) ==
             {:ok, %{cursor: 0, inserted: 0}}

    assert Activity.sync(session, OversizedAPI, :client) ==
             {:error, {:invalid_coop_activity, :page}}

    assert Activity.sync(session, ErrorAPI, :client) == {:error, :unavailable}
    assert Repo.get!(Responder.Work.Session, session.id).activity_sync_pending

    assert Activity.retry_once(EmptyAPI, :client) == {:ok, {:synced, session.id}}
    refute Repo.get!(Responder.Work.Session, session.id).activity_sync_pending
    assert Activity.retry_once(EmptyAPI, :client) == {:ok, :idle}
    assert Activity.retry_once("not-an-api", :client) == {:error, {:invalid_coop_activity, :api}}

    assert Activity.ingest(:invalid, []) == {:error, {:invalid_coop_activity, :page}}

    assert Activity.ingest_fleet(:invalid, "remote", 0, []) ==
             {:error, {:invalid_coop_activity, :page}}

    assert Activity.ingest_fleet(session.id, "another-session", 12, []) ==
             {:error, {:coop_activity_session_conflict, "another-session"}}

    assert Activity.ingest(Ecto.UUID.generate(), []) == {:error, :work_session_not_found}
    assert Activity.list_for_episode(nil) == []

    assert Activity.page_for_episode(nil) == %{
             events: [],
             shown: 0,
             tool_calls: 0,
             total: 0,
             truncated: false
           }

    invalid = event(session, 13, "model.plan", %{"entries" => []})

    for {changed, field} <- [
          {Map.put(invalid, "extra", true), :event},
          {Map.put(invalid, "id", 5), :event_id},
          {Map.put(invalid, "session_id", "another-session"), :event},
          {Map.put(invalid, "sequence", 0), :sequence},
          {Map.put(invalid, "version", 0), :version},
          {Map.put(invalid, "occurred_at", "not-a-time"), :occurred_at},
          {Map.put(invalid, "occurred_at", nil), :occurred_at},
          {Map.put(invalid, "payload", []), :event}
        ] do
      assert Activity.ingest(session.id, [changed]) ==
               {:error, {:invalid_coop_activity, field}}
    end

    assert Activity.ingest(session.id, [:invalid]) ==
             {:error, {:invalid_coop_activity, :event}}

    assert Activity.ingest(session.id, [
             event(session, 14, "session.updated", %{}),
             event(session, 13, "session.updated", %{})
           ]) == {:error, {:invalid_coop_activity, :sequence}}
  end

  test "the episode projection keeps the newest activity and reports omitted history" do
    episode_id = Ecto.UUID.generate()

    assert {:ok, started} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: "activity-window:#{episode_id}",
                 native_input_id: "activity-window-input:#{episode_id}",
                 occurred_at: @now,
                 turn_ref: "activity-window-turn:#{episode_id}"
               })
             )

    assert {:ok, session} =
             Custody.pin_episode(started.episode.id, "policy:activity", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("activity-window-recorder", 60, :work)

    assert {:ok, session} =
             Custody.bind_session(
               started.episode.id,
               claim.turn.turn_ref,
               claim.lease_ref,
               session.generation,
               session.create_generation,
               "remote:window:#{session.id}"
             )

    first_page = Enum.map(1..1_000, &event(session, &1, "model.thought", %{}))
    final_page = [event(session, 1_001, "model.thought", %{})]

    assert {:ok, %{cursor: 1_001, inserted: 1_001}} =
             Activity.sync(session, PagedAPI, %{0 => first_page, 1_000 => final_page})

    persisted_session = Repo.get!(Responder.Work.Session, session.id)

    assert Activity.sync(persisted_session, PagedAPI, %{1_001 => first_page}) ==
             {:error, {:invalid_coop_activity, :stalled_cursor}}

    page = Activity.page_for_episode(episode_id)

    assert page.total == 1_001
    assert page.shown == 1_000
    assert page.truncated
    assert hd(page.events).sequence == 2
    assert List.last(page.events).sequence == 1_001
  end

  test "the sync worker polls the durable retry queue on a bounded interval" do
    assert ActivitySyncWorker.init(api: EmptyAPI, poll_interval_ms: 0) ==
             {:stop, {:invalid_activity_sync_worker, :options}}

    assert {:ok, state} =
             ActivitySyncWorker.init(api: EmptyAPI, client: :client, poll_interval_ms: 60_000)

    assert {:noreply, ^state} = ActivitySyncWorker.handle_info(:poll, state)
  end

  defp event(session, sequence, type, payload) do
    %{
      "id" => "event-#{sequence}",
      "occurred_at" => DateTime.add(@now, sequence, :second) |> DateTime.to_iso8601(),
      "payload" => payload,
      "sequence" => sequence,
      "session_id" => session.coop_session_id,
      "turn_id" => "remote-turn:#{session.id}",
      "type" => type,
      "version" => 1
    }
  end
end
