defmodule Responder.Work.ActivityTest do
  alias Responder.ControlPlane.Projection
  use Responder.DataCase, async: false

  defmodule OversizedAPI do
    def list_events(_client, _session_id, _cursor, _limit),
      do: {:ok, List.duplicate(%{}, 1_001)}
  end

  defmodule ErrorAPI do
    def list_events(_client, _session_id, _cursor, _limit), do: {:error, :unavailable}
  end

  defmodule RaisingAPI do
    def list_events(_, _, _, _), do: raise("transport unavailable")
  end

  defmodule EmptyAPI do
    def list_events(_client, _session_id, _cursor, _limit), do: {:ok, []}
  end

  defmodule PagedAPI do
    def list_events(pages, _session_id, cursor, _limit), do: {:ok, Map.get(pages, cursor, [])}
  end

  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Work.{Activity, ActivitySyncWorker, Custody}

  @now ~U[2026-09-04 12:00:00.000000Z]

  test "native tool errors and public progress survive ingestion with safe evidence" do
    # The Sept 6 infra run showed failed plan_goal without its arguments or error, hiding the cause.
    {:ok, started} = Episodes.apply(EpisodeFixtures.admit_input())

    {:ok, session} =
      Custody.pin_episode(started.episode.id, "policy:activity", String.duplicate("a", 64))

    {:ok, claim} = Custody.claim_next("activity-evidence", 60, :work)

    {:ok, session} =
      Custody.bind_session(
        started.episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        session.generation,
        session.create_generation,
        "remote:evidence"
      )

    events = [
      event(session, 1, "tool.started", %{
        "tool_call_id" => "exec-fea1da1f",
        "title" => "responder-state · plan_goal",
        "kind" => "mcp",
        "input" => %{
          "server" => "responder-state",
          "tool" => "plan_goal",
          "arguments" => %{"read_only_repositories" => ["emisar"], "token" => "must-not-survive"}
        }
      }),
      event(session, 2, "tool.completed", %{
        "tool_call_id" => "exec-fea1da1f",
        "status" => "failed",
        "output" => %{"error" => "unauthorized"}
      }),
      event(session, 3, "model.progress", %{"text" => "Checking both production runners."}),
      event(session, 4, "model.thought", %{"text" => "private reasoning"})
    ]

    assert {:ok, %{inserted: 4}} = Activity.ingest(session.id, events)
    assert [start, finish, progress, thought] = Activity.list_for_episode(started.episode.id)
    assert start.payload["input"]["arguments"]["read_only_repositories"] == ["emisar"]
    assert start.payload["input"]["arguments"]["token"] == "[redacted]"
    assert finish.payload["output"] == %{"error" => "unauthorized"}
    assert progress.payload["text"] == "Checking both production runners."
    assert thought.payload == %{}
    assert {:ok, %{inserted: 0}} = Activity.ingest(session.id, events)

    # Secret rotation must not change replay identity or restore an already-redacted body.
    Application.put_env(:responder, :activity_test_secret, "opaque-private-value")
    on_exit(fn -> Application.delete_env(:responder, :activity_test_secret) end)
    secret_event = event(session, 5, "model.progress", %{"text" => "opaque-private-value"})
    assert {:ok, %{inserted: 1}} = Activity.ingest(session.id, [secret_event])
    Application.put_env(:responder, :activity_test_secret, "rotated-private-value")
    assert {:ok, %{inserted: 0}} = Activity.ingest(session.id, [secret_event])
    refute inspect(Activity.list_for_episode(started.episode.id)) =~ "opaque-private-value"
    changed = put_in(secret_event, ["payload", "text"], "different text")
    assert {:error, {:coop_activity_replay_conflict, 5}} = Activity.ingest(session.id, [changed])
    assert {:error, :coop_activity_unavailable} = Activity.sync(session, RaisingAPI, nil)

    # Keep a complete public message through redaction, including secrets that
    # straddled Coop's former 4 KiB event boundary. Only then bound display text.
    Application.put_env(:responder, :activity_test_secret, "opaque-configured-secret")

    long_text =
      String.duplicate("🙂", 1_023) <> "opaque-configured-secret" <> String.duplicate("x", 13_000)

    assert {:ok, %{inserted: 1}} =
             Activity.ingest(session.id, [
               event(session, 6, "model.progress", %{"text" => long_text})
             ])

    last = Activity.list_for_episode(started.episode.id) |> List.last()
    assert last.payload["text"] =~ "[redacted]"
    refute last.payload["text"] =~ "opaque-configured-secret"

    {:ok, detail} = Projection.episode(started.episode.key)
    tool = Enum.find(detail.trace.steps, &(&1.stage == "Tool call"))
    assert tool.summary =~ "unauthorized"
    assert Enum.any?(tool.artifacts, &(&1.label == "Arguments" && &1.artifact.text =~ "emisar"))
    refute Enum.any?(detail.trace.steps, &(&1.title == "Model reasoning checkpoint"))
  end

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

    assert started_tool.payload["input"]["action_id"] == "nomad.job_status"
    assert started_tool.payload["input"]["args"] == %{"job" => "responder"}
    assert started_tool.payload["title"] == "mcp.emisar.run_action"

    assert completed_tool.kind == "tool.completed"

    assert Map.take(completed_tool.payload, ~w(status tool_call_id)) == %{
             "status" => "completed",
             "tool_call_id" => "tool-1"
           }

    # An upgrade must accept redelivery of a row stored by the old lossy projection.
    legacy = %{"tool_call_id" => "tool-1", "input" => %{"operation" => "nomad.job_status"}}

    started_tool
    |> Ecto.Changeset.change(
      payload: legacy,
      payload_fingerprint: Responder.CanonicalJSON.digest(legacy)
    )
    |> Repo.update!()

    assert {:ok, %{inserted: 0}} = Activity.ingest(session.id, events)

    assert Repo.get!(Responder.Work.ActivityEvent, started_tool.id).payload["input"]["args"] == %{
             "job" => "responder"
           }

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

    assert plan.payload["step_count"] == 1
    assert plan.payload["entries"] == [%{"text" => "private plan text"}]
    refute Map.has_key?(plan.payload, "private")

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
    assert empty_plan.payload == %{"step_count" => 0, "entries" => [], "evidence_version" => 1}
    assert filtered_backoff.payload == %{"reset_at" => "2026-09-04T12:05:00Z"}
    assert tool.payload["input"] == %{"arguments" => %{"action_id" => "nomad.allocations"}}

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

    # The HTTP endpoint can return a short page at its byte limit. A short
    # page is not the end: otherwise terminal tool results disappear forever.
    first_page = Enum.map(1..2, &event(session, &1, "model.thought", %{}))
    final_page = Enum.map(3..1_001, &event(session, &1, "model.thought", %{}))

    assert {:ok, %{cursor: 1_001, inserted: 1_001}} =
             Activity.sync(session, PagedAPI, %{0 => first_page, 2 => final_page})

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
