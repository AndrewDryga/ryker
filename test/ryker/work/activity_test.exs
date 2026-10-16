defmodule Ryker.Work.ActivityTest do
  use Ryker.DataCase, async: false
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  alias Ryker.Config
  alias Ryker.ControlPlane.{EpisodeProjection, ToolCard}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.Learning, as: LearningFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Learning
  alias Ryker.Learning.FleetSession
  alias Ryker.Work.{Activity, ActivitySyncWorker, Custody}

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

  @now ~U[2026-09-04 12:00:00.000000Z]

  test "stored file paths are re-redacted when a secret is configured after ingestion" do
    # Relative path facts introduced another visible copy of a filename. Rotating
    # secrets must redact that copy too, without changing the historical event.
    {:ok, started} = Episodes.apply(EpisodeFixtures.admit_input())

    {:ok, session} =
      WorkSessions.pin_episode(started.episode.id, "policy:paths", String.duplicate("a", 64))

    {:ok, claim} = Custody.claim_next("path-redaction", 60, :work)

    {:ok, session} =
      Custody.bind_session(
        started.episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        session.generation,
        session.create_generation,
        "remote:path-redaction"
      )

    secret = "future-file-secret-value"

    paths = %{
      "basis" => "lexical",
      "paths" => [
        %{"source" => "/locations/0/path", "scope" => "project", "path" => "lib/#{secret}.ex"}
      ]
    }

    payload = %{"tool_call_id" => "read-pair", "kind" => "read", "path_context" => paths}

    events = [
      event(session, 1, "tool.started", payload),
      event(session, 2, "tool.completed", Map.put(payload, "status", "completed")),
      event(
        session,
        3,
        "tool.completed",
        Map.merge(payload, %{"tool_call_id" => "read-late", "status" => "completed"})
      )
    ]

    assert {:ok, %{inserted: 3}} = Activity.ingest(session.id, events)

    assert Enum.all?(
             Activity.page_for_episode(started.episode.id).events,
             &(inspect(&1.payload) =~ secret)
           )

    Config.put_override(:activity_path_test_secret, secret)

    {:ok, detail} = EpisodeProjection.fetch(started.episode.key)
    steps = Enum.filter(detail.trace.steps, &String.starts_with?(&1.id, "activity-"))
    assert length(steps) == 2

    for step <- steps do
      refute inspect(step.path_context) =~ secret
      assert inspect(step.path_context) =~ "[redacted]"

      html =
        render_component(&ToolCard.render/1,
          step: step
        )

      refute html =~ secret
    end

    assert Enum.all?(
             Activity.page_for_episode(started.episode.id).events,
             &(inspect(&1.payload) =~ secret)
           )
  end

  test "native tool errors and public progress survive ingestion with safe evidence" do
    # The Sept 6 infra run showed failed plan_goal without its arguments or error, hiding the cause.
    {:ok, started} = Episodes.apply(EpisodeFixtures.admit_input())

    {:ok, session} =
      WorkSessions.pin_episode(started.episode.id, "policy:activity", String.duplicate("a", 64))

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
        "title" => "controller-tools · plan_goal",
        "kind" => "mcp",
        "input" => %{
          "server" => "controller-tools",
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
      event(session, 4, "model.thought", %{"text" => "**Comparing the two runners**"})
    ]

    assert {:ok, %{inserted: 4}} = Activity.ingest(session.id, events)

    assert [start, finish, progress, thought] =
             Activity.page_for_episode(started.episode.id).events

    assert start.payload["input"]["arguments"]["read_only_repositories"] == ["emisar"]
    assert start.payload["input"]["arguments"]["token"] == "[redacted]"
    assert finish.payload["output"] == %{"error" => "unauthorized"}
    assert progress.payload["text"] == "Checking both production runners."
    # A thought is kept in words since 2026-09-29 ("workers must report
    # commands, thinking and everything else"), redacted like progress.
    assert thought.payload["text"] == "**Comparing the two runners**"
    assert {:ok, %{inserted: 0}} = Activity.ingest(session.id, events)

    # Secret rotation must not change replay identity or restore an already-redacted body.
    Config.put_override(:activity_test_secret, "opaque-private-value")
    secret_event = event(session, 5, "model.progress", %{"text" => "opaque-private-value"})
    assert {:ok, %{inserted: 1}} = Activity.ingest(session.id, [secret_event])
    Config.put_override(:activity_test_secret, "rotated-private-value")
    assert {:ok, %{inserted: 0}} = Activity.ingest(session.id, [secret_event])
    refute inspect(Activity.page_for_episode(started.episode.id).events) =~ "opaque-private-value"
    changed = put_in(secret_event, ["payload", "text"], "different text")
    assert Activity.ingest(session.id, [changed]) == {:error, {:coop_activity_replay_conflict, 5}}

    # Keep a complete public message through redaction, including secrets that
    # straddled Coop's former 4 KiB event boundary. Only then bound display text.
    Config.put_override(:activity_test_secret, "opaque-configured-secret")

    long_text =
      String.duplicate("🙂", 1_023) <> "opaque-configured-secret" <> String.duplicate("x", 13_000)

    assert {:ok, %{inserted: 1}} =
             Activity.ingest(session.id, [
               event(session, 6, "model.progress", %{"text" => long_text})
             ])

    last = Activity.page_for_episode(started.episode.id).events |> List.last()
    assert last.payload["text"] =~ "[redacted]"
    refute last.payload["text"] =~ "opaque-configured-secret"

    {:ok, detail} = EpisodeProjection.fetch(started.episode.key)
    tool = Enum.find(detail.trace.steps, &(&1.stage == "Tool call" && &1.state == "failed"))
    refute Enum.any?(detail.trace.steps, &(&1.stage == "Tool call" && &1.state == "started"))
    assert tool.duration_ms == 1_000
    assert tool.summary =~ "unauthorized"
    assert Enum.any?(tool.artifacts, &(&1.label == "Arguments" && &1.artifact.text =~ "emisar"))
    refute Enum.any?(detail.trace.steps, &(&1.title == "Model reasoning checkpoint"))

    # A late path is merged into the one completed card for the call.
    paths = %{
      "basis" => "lexical",
      "paths" => [
        %{"source" => "/locations/0/path", "scope" => "project", "path" => "lib/config.ex"},
        %{"source" => "/locations/1/path", "scope" => "outside"}
      ]
    }

    assert {:ok, %{inserted: 2}} =
             Activity.ingest(session.id, [
               event(session, 7, "tool.started", %{
                 "tool_call_id" => "native-read",
                 "title" => "Read file 'config.ex'"
               }),
               event(session, 8, "tool.completed", %{
                 "tool_call_id" => "native-read",
                 "kind" => "read",
                 "status" => "completed",
                 "path_context" => paths
               })
             ])

    {:ok, detail} = EpisodeProjection.fetch(started.episode.key)
    reads = Enum.filter(detail.trace.steps, &(&1.title == "Read file 'config.ex'"))
    assert [read] = reads
    assert Map.get(read, :path_context) == paths
    assert read.tool_kind == "read"
  end

  # A raise while reading a session's activity answered "unavailable" and
  # logged nothing, so a bug in Ryker read as Coop being down (2026-10-04
  # review).
  test "an activity read that raises is logged, and the sync still answers softly" do
    {:ok, started} = Episodes.apply(EpisodeFixtures.admit_input())

    {:ok, session} =
      WorkSessions.pin_episode(started.episode.id, "policy:activity", String.duplicate("a", 64))

    {:ok, claim} = Custody.claim_next("activity-raise", 60, :work)

    {:ok, session} =
      Custody.bind_session(
        started.episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        session.generation,
        session.create_generation,
        "remote:activity-raise"
      )

    log =
      capture_log(fn ->
        assert Activity.sync(session, RaisingAPI, nil) == {:error, :coop_activity_unavailable}
      end)

    assert log =~ "Coop activity read raised"
    assert log =~ "transport unavailable"
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
             WorkSessions.pin_episode(
               started.episode.id,
               "policy:activity",
               String.duplicate("a", 64)
             )

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
        "input" => %{"action_id" => "nomad.job_status", "args" => %{"job" => "ryker"}},
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

    assert [thought, started_tool, completed_tool] = Activity.page_for_episode(episode_id).events
    assert thought.kind == "model.thought"

    assert thought.payload == %{
             "evidence_version" => 1,
             "text" => "Checking the runtime state.",
             "truncated" => false
           }

    assert started_tool.kind == "tool.started"

    assert started_tool.payload["input"]["action_id"] == "nomad.job_status"
    assert started_tool.payload["input"]["args"] == %{"job" => "ryker"}
    assert started_tool.payload["title"] == "mcp.emisar.run_action"

    assert completed_tool.kind == "tool.completed"

    assert Map.take(completed_tool.payload, ~w(status tool_call_id)) == %{
             "status" => "completed",
             "tool_call_id" => "tool-1"
           }

    changed_identity = events |> Enum.at(1) |> Map.put("id", "event-2-changed")

    assert Activity.ingest(session.id, [changed_identity]) ==
             {:error, {:coop_activity_replay_conflict, 2}}

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
             Activity.page_for_episode(episode_id).events |> Enum.take(-8)

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

    assert Activity.ingest(session.id, [event(session, 14, "model.plan", %{"entries" => []})]) ==
             {:error, {:coop_activity_cursor_gap, 13, 14}}

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
    assert Repo.get!(Ryker.Work.Session, session.id).activity_sync_pending

    assert Activity.retry_once(EmptyAPI, :client) == {:ok, {:synced, session.id}}
    refute Repo.get!(Ryker.Work.Session, session.id).activity_sync_pending
    assert Activity.retry_once(EmptyAPI, :client) == {:ok, :idle}
    assert Activity.retry_once("not-an-api", :client) == {:error, {:invalid_coop_activity, :api}}

    assert Activity.ingest(:invalid, []) == {:error, {:invalid_coop_activity, :page}}

    assert Activity.ingest_fleet(:invalid, "remote", 0, []) ==
             {:error, {:invalid_coop_activity, :page}}

    assert Activity.ingest_fleet(session.id, "another-session", 12, []) ==
             {:error, {:coop_activity_session_conflict, "another-session"}}

    assert Activity.ingest(Ecto.UUID.generate(), []) == {:error, :work_session_not_found}
    assert Activity.page_for_episode(nil).events == []

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
             WorkSessions.pin_episode(
               started.episode.id,
               "policy:activity",
               String.duplicate("a", 64)
             )

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

    persisted_session = Repo.get!(Ryker.Work.Session, session.id)

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

  test "a sealed run's network refusals reach the timeline as counts, never as names" do
    # Coop appends the `network` event when a filtered run hits its boundary. It
    # is the run's own chronological record of what was refused; the session-wide
    # totals live in the evidence capture. The daemon already applied its policy's
    # destination projection, so a withheld name arrives as the literal
    # "name withheld" -- and no field the worker did not promise may cross.
    {:ok, started} = Episodes.apply(EpisodeFixtures.admit_input())

    {:ok, session} =
      WorkSessions.pin_episode(started.episode.id, "policy:network", String.duplicate("a", 64))

    {:ok, claim} = Custody.claim_next("network-activity", 60, :work)

    {:ok, session} =
      Custody.bind_session(
        started.episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        session.generation,
        session.create_generation,
        "remote:network-activity"
      )

    payload = %{
      "version" => 1,
      "run_id" => "run-7f3a",
      "denials" => [
        %{
          "destination" => "name withheld",
          "basis" => "tls",
          "count" => 3,
          "peer" => "203.0.113.9"
        }
      ],
      "omitted_destinations" => 4,
      "alerts" => ["collector degraded"],
      "allowed_traffic" => "1 connection, 10 B sent",
      "detail_truncated" => true,
      "evidence_id" => "evt-0031",
      "internal_note" => "do not export"
    }

    assert {:ok, %{inserted: 1}} =
             Activity.ingest(session.id, [event(session, 1, "network", payload)])

    assert [stored] = Activity.page_for_episode(started.episode.id).events
    assert stored.kind == "network"
    assert stored.payload["run_id"] == "run-7f3a"
    assert stored.payload["omitted_destinations"] == 4
    assert stored.payload["detail_truncated"] == true
    assert stored.payload["alerts"] == ["collector degraded"]
    assert [denial] = stored.payload["denials"]
    assert denial["destination"] == "name withheld"
    assert denial["count"] == 3

    # Only the three promised denial fields cross, and nothing else in the event.
    refute Map.has_key?(denial, "peer")
    refute inspect(stored.payload) =~ "203.0.113.9"
    refute inspect(stored.payload) =~ "internal_note"
    refute inspect(stored.payload) =~ "do not export"
  end

  test "a sent prompt's record is kept for its model call, off the timeline, and an unreadable one does not stop the stream" do
    # The worker records what each prompt it sends carried: Ryker's prompt and
    # response format by digest, and the text Coop wrote around them as sent.
    # Ryker showed only its own saved prompt as the prompt a model was given
    # (2026-10-15). A record this cannot read is kept as unreadable: refusing
    # it would refuse the page, and a refused page stops the worker's stream.
    {:ok, started} = Episodes.apply(EpisodeFixtures.admit_input())

    {:ok, session} =
      WorkSessions.pin_episode(started.episode.id, "policy:prompts", String.duplicate("a", 64))

    {:ok, claim} = Custody.claim_next("prompt-records", 60, :work)

    {:ok, session} =
      Custody.bind_session(
        started.episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        session.generation,
        session.create_generation,
        "remote:prompt-records"
      )

    note =
      "\n\n<coop-output>Save only final generated images in .coop-output/turn-1.</coop-output>"

    token = "ghp_" <> String.duplicate("aB7C", 9)
    quoted = "Your previous final response was rejected: " <> token

    sent = %{
      "version" => 1,
      "state" => "sent",
      "text_sha256" => digest("prompt" <> note),
      "text_bytes" => byte_size("prompt" <> note),
      "parts" => [
        %{"kind" => "caller_prompt", "sha256" => digest("prompt"), "bytes" => 6},
        %{"kind" => "text", "text" => note, "sha256" => digest(note), "bytes" => byte_size(note)},
        %{
          "kind" => "text",
          "text" => quoted,
          "sha256" => digest(quoted),
          "bytes" => byte_size(quoted)
        }
      ],
      "blocks" => [
        %{
          "type" => "image",
          "name" => "chart.png",
          "media_type" => "image/png",
          "sha256" => digest("png"),
          "bytes" => 3,
          "data" => "cG5n"
        }
      ],
      "checkout_root" => "/private/workspace"
    }

    unreadable =
      put_in(sent, ["parts"], [
        %{"kind" => "text", "text" => note, "sha256" => digest("other"), "bytes" => 9}
      ])

    events = [
      event(session, 1, "tool.started", %{"tool_call_id" => "exec-1", "title" => "Run git status"}),
      event(session, 2, "prompt.sent", sent),
      event(session, 3, "prompt.sent", unreadable)
    ]

    assert {:ok, %{cursor: 3, inserted: 3}} = Activity.ingest(session.id, events)

    assert [narrated] = Activity.page_for_episode(started.episode.id).events
    assert narrated.kind == "tool.started"

    [kept, unread] =
      Ryker.Work.ActivityEvent
      |> Repo.all()
      |> Enum.filter(&(&1.kind == "prompt.sent"))
      |> Enum.sort_by(& &1.sequence)

    assert unread.payload == %{"unreadable" => true}
    assert kept.payload["state"] == "sent"
    assert kept.payload["text_sha256"] == digest("prompt" <> note)
    assert [prompt, folder, correction] = kept.payload["parts"]
    assert prompt == %{"kind" => "caller_prompt", "sha256" => digest("prompt"), "bytes" => 6}
    assert folder["text"] == note
    assert correction["redacted"] == true
    refute inspect(kept.payload) =~ token
    refute inspect(kept.payload) =~ "/private/workspace"
    assert [%{"name" => "chart.png", "bytes" => 3} = block] = kept.payload["blocks"]
    refute Map.has_key?(block, "data")
  end

  test "a learning session keeps only what its worker sent, and its narration is acknowledged" do
    # Retained activity belongs to exactly one owner, an episode or an admission
    # input, and a learning session has neither. On 2026-09-13 the first learning
    # session to narrate a tool call tripped that check constraint as a raised
    # Ecto.ConstraintError, every worker sync answered 500 from then on, and the
    # fleet delivered no command for the next thirty-seven minutes: 2,625 raises,
    # twenty-one expired placements, and both Slack inputs blocked. The worker
    # must be acknowledged and move on; ownerless narration is not retained.
    # The record of what its worker sent is, for its run's card (2026-10-16).
    entries = LearningFixtures.inputs!()

    assert {:ok, run} =
             Learning.prepare(Enum.map(entries, & &1.id), %{
               policy: "recorded-read-only-policy",
               policy_digest: String.duplicate("a", 64)
             })

    assert {:ok, _session} = FleetSession.ensure(run)
    assert {:ok, session} = FleetSession.bind(run, "remote:learning")

    events = [
      event(session, 1, "tool.started", %{
        "tool_call_id" => "exec-learn",
        "title" => "controller-tools · recall",
        "kind" => "mcp",
        "input" => %{"server" => "controller-tools", "tool" => "recall", "arguments" => %{}}
      }),
      event(session, 2, "tool.completed", %{
        "tool_call_id" => "exec-learn",
        "status" => "completed",
        "output" => %{}
      }),
      event(session, 3, "prompt.sent", %{
        "version" => 1,
        "state" => "sent",
        "text_sha256" => digest("prompt"),
        "text_bytes" => 6,
        "parts" => [%{"kind" => "caller_prompt", "sha256" => digest("prompt"), "bytes" => 6}],
        "blocks" => []
      })
    ]

    assert {:ok, %{cursor: 3, inserted: 1}} =
             Activity.ingest_fleet(session.id, "remote:learning", 0, events)

    assert [kept] = Repo.all(Ryker.Work.ActivityEvent)

    assert {kept.kind, kept.session_id, kept.episode_id, kept.admission_input_id} ==
             {"prompt.sent", session.id, nil, nil}

    # A replayed page finds the record it kept, and the narration it never
    # kept does not refuse the page: a refused page stops the worker's stream.
    assert {:ok, %{cursor: 3, inserted: 0}} =
             Activity.ingest_fleet(session.id, "remote:learning", 3, events)
  end

  defp digest(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

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
