defmodule Responder.Evals.WorldRunnerTest do
  use Responder.DataCase, async: false

  @moduletag isolation: "REPEATABLE READ"

  import Ecto.Query

  alias Responder.Artifacts.Outputs
  alias Responder.Delivery.Adapters
  alias Responder.Delivery.Dispatcher, as: DeliveryDispatcher
  alias Responder.Episodes
  alias Responder.Episodes.Command

  alias Responder.Evals.{
    SlackDeliveryPublisher,
    WorldCase,
    WorldCassette,
    WorldCoverage,
    WorldJudgeCase,
    WorldReport,
    WorldRunner
  }

  alias Responder.Repo
  alias Responder.Slack.ChannelConfiguration
  alias Responder.State.{EventSubscription, EventWaits, Record, Records}
  alias Responder.StateTools.Tools
  alias Responder.TestSupport.{FakeWorkCoopAPI, WorldHostReplay}
  alias Responder.Work.{Custody, Submission, Turn}
  alias Responder.Work.Dispatcher, as: WorkDispatcher

  @policy_digest String.duplicate("a", 64)

  @state_scenarios [
    {"rivals-engineering-task-offer", "request_task"},
    {"material-rollout-choice-asks-once", "request_input"},
    {"airflow-verification-arms-wait", "wait_for"},
    {"confirmed-guidance-becomes-memory", "propose_memory"},
    {"weekly-health-review-offers-schedule", "propose_automation"}
  ]

  @platform_scenarios [
    {"github-pr-review-remains-in-thread", "github"},
    {"universal-webhook-unknown-payload", "slack"}
  ]

  @core_host_scenarios ~w(
    application-errors-follow-the-current-signal
    artifact-delivery-survives-work-handoff
    creative-request-needs-no-fake-evidence
    current-uptime-check-uses-fresh-source
    grafana-firing-resolved-stays-in-cycle
    noisy-context-keeps-current-request
    ordinary-thread-question-gets-natural-answer
  )

  defmodule TerminalWorkAPI do
    @moduledoc false

    defdelegate capabilities(client), to: FakeWorkCoopAPI
    defdelegate operation_by_key(client, key), to: FakeWorkCoopAPI
    defdelegate create_session(client, key, policy, task), to: FakeWorkCoopAPI
    defdelegate get_session(client, session_id), to: FakeWorkCoopAPI
    defdelegate get_turn(client, session_id, turn_id), to: FakeWorkCoopAPI
    defdelegate list_events(client, session_id, after_sequence, limit), to: FakeWorkCoopAPI
    defdelegate close_session(client, session_id, key, revision), to: FakeWorkCoopAPI

    def submit_frozen_turn(client, session_id, key, revision, submission, binding, artifacts) do
      {:ok, response} =
        FakeWorkCoopAPI.submit_frozen_turn(
          client,
          session_id,
          key,
          revision,
          submission,
          binding,
          artifacts
        )

      turn =
        response["turn"]
        |> Map.put("state", "failed")
        |> Map.put("candidate", nil)
        |> Map.put("error_code", "provider_unavailable")
        |> Map.put("error_detail", "Provider stopped this turn.")

      FakeWorkCoopAPI.update(client, &%{&1 | turn: turn})
      {:ok, %{response | "turn" => turn}}
    end
  end

  test "a blocked model world's error exports metadata without its saved submission" do
    # Preserving failed runs exposed the full Turn through an inspected error,
    # bypassing the normal candidate sanitizer and copying prompts into reports.
    {:ok, scenario} = WorldCase.fetch("ordinary-thread-question-gets-natural-answer")
    {:ok, fake} = FakeWorkCoopAPI.start_link([])
    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)
    {:ok, before_execute} = WorldHostReplay.before_execute(scenario, fake)

    assert {:error, {:world_eval_assertions, report}} =
             WorldRunner.run(scenario,
               api: TerminalWorkAPI,
               before_execute: before_execute,
               client: fake,
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret",
               worker_ref: "world-terminal-error"
             )

    assert report.status == :failed
    assert [%{turn_id: turn_id}] = report.runtime.turns
    turn = Repo.get!(Turn, turn_id)
    assert turn.status == :blocked
    assert is_binary(turn.submission["prompt"])
    assert FakeWorkCoopAPI.state(fake).submit_count == 1
    assert FakeWorkCoopAPI.state(fake).session["state"] == "closed"

    assert report.execution_error ==
             {:world_eval_failed,
              {:work_not_accepted, %{status: :blocked, turn_id: turn_id, turn_status: :blocked}}}

    assert {:ok, result} =
             WorldReport.result(Map.merge(report, %{lane: :candidate, repeat_index: 1}))

    refute result["execution_error"] =~ "submission"
    refute result["execution_error"] =~ "delivery_document"
    refute result["execution_error"] =~ "Responder.Work.Turn"
    assert result["execution_error"] =~ turn_id
    assert Repo.get!(Turn, turn_id).submission == turn.submission
  end

  test "cleanup diagnostics preserve the primary model-world failure" do
    primary_report = %{
      status: :failed,
      failures: [],
      execution_error: {:world_eval_failed, :work_retry_exhausted}
    }

    primary = {:error, {:world_eval_assertions, primary_report}}
    cleanup = {:error, {:world_cleanup_blocked, :session_cleanup_error}}

    assert {:error, {:world_eval_assertions, report}} =
             WorldRunner.finish_result(primary, cleanup)

    assert report.execution_error == primary_report.execution_error
    assert report.cleanup_error == {:world_cleanup_blocked, :session_cleanup_error}
    assert report.failures == []
  end

  test "an authority mismatch submits no model turn and remains visible after retries" do
    # Nine real eval sessions were created but never submitted: the stale policy
    # pin was hidden behind the harness's generic work_retry_exhausted result.
    {:ok, scenario} = WorldCase.fetch("ordinary-thread-question-gets-natural-answer")
    {:ok, fake} = FakeWorkCoopAPI.start_link([])

    FakeWorkCoopAPI.update(fake, fn state ->
      put_in(state, [:session, "policy_digest"], String.duplicate("b", 64))
    end)

    result =
      WorldRunner.run(scenario,
        api: FakeWorkCoopAPI,
        client: fake,
        policy: "world-eval-read-only",
        policy_digest: @policy_digest,
        state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
        state_tools_secret: "world-eval-state-tools-secret",
        worker_ref: "world-eval-authority"
      )

    assert FakeWorkCoopAPI.state(fake).submit_count == 0

    assert {:error, {:world_eval_assertions, report}} = result
    assert report.status == :unrun
    assert report.runtime.turns == []
    assert report.failures == []

    assert report.execution_error ==
             {:world_eval_failed,
              {:work_retry_exhausted, {:coop_protocol_error, :session_authority}}}
  end

  test "cleanup diagnostics do not change a successful cleanup result" do
    success = {:ok, %{status: :passed}}

    assert success == WorldRunner.finish_result(success, :ok)
  end

  test "a failed world cannot attribute another episode's remote turn to its model" do
    {:ok, scenario} = WorldCase.fetch("ordinary-thread-question-gets-natural-answer")
    {:ok, fake} = FakeWorkCoopAPI.start_link([])
    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)

    FakeWorkCoopAPI.update(
      fake,
      &put_in(&1, [:session, "policy_digest"], String.duplicate("b", 64))
    )

    before_execute = fn claim, _scenario ->
      other_id = Ecto.UUID.generate()

      assert {:ok, _} =
               Episodes.apply(%Command.AdmitInput{
                 actor_ref: "eval:other-source",
                 destination: %{
                   conversation_ref: "slack:TOTHER:COTHER",
                   thread_ref: nil,
                   transport: "slack"
                 },
                 episode_id: other_id,
                 episode_key: "eval:other:" <> other_id,
                 native_input_id: "eval:other-input:" <> other_id,
                 occurred_at: DateTime.utc_now(),
                 payload: %{"text" => "Other episode custody"},
                 revision: 1,
                 turn_ref: "eval:other-turn:" <> other_id
               })

      assert {:ok, _} = Custody.pin_episode(other_id, "world-eval-read-only", @policy_digest)
      assert {:ok, other} = Custody.claim_next("other-eval-worker", 300, :work)
      assert other.episode.id != claim.episode.id

      assert {1, _} =
               Repo.update_all(from(turn in Turn, where: turn.id == ^other.turn.id),
                 set: [coop_turn_id: "remote-turn-owned-by-other-episode"]
               )

      :ok
    end

    assert {:error, {:world_eval_assertions, report}} =
             WorldRunner.run(scenario,
               api: FakeWorkCoopAPI,
               before_execute: before_execute,
               client: fake,
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret",
               worker_ref: "world-identity-isolation"
             )

    assert report.status == :unrun
    assert report.runtime.turns == []

    assert report.execution_error ==
             {:world_eval_failed,
              {:work_retry_exhausted, {:coop_protocol_error, :session_authority}}}
  end

  test "read-only wait planning remains authorized across source-event turns" do
    # The real Airflow smoke created read-only check goals and five ordinary
    # progress transitions; the eval rejected them as effectful operations.
    # The September 9 qualification repeated that false failure for a schedule-
    # labelled read-only child and its two updates, stopping the nine-case lane.
    captured =
      "testdata/eval/airflow-read-only-wait-planning.json" |> File.read!() |> Jason.decode!()

    {:ok, scenario} = WorldCase.fetch("airflow-verification-arms-wait")
    {:ok, fake} = FakeWorkCoopAPI.start_link([])
    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)
    {:ok, cassette} = start_supervised({WorldCassette, scenario})
    {:ok, replay} = WorldHostReplay.before_execute(scenario, fake, cassette: cassette)
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)

    before_execute = fn claim, world ->
      index = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})

      if index == 1 do
        assert {:ok, _} =
                 Tools.call("plan_goal", recorded_read_only_goal(), binding_options(claim))

        for record <- captured["records"] do
          # Only adapt the parent identity to this existing structural harness.
          # Every other field is the captured public goal or progress payload.
          {tool, payload} =
            case record["kind"] do
              "goal" ->
                {"plan_goal",
                 Map.put(record["payload"], "parent_goal_id", "airflow-verification-context")}

              "goal_state" ->
                {"update_goal", record["payload"]}
            end

          assert {:ok, _} = Tools.call(tool, payload, binding_options(claim))
        end
      end

      assert {:ok, _} =
               Tools.call(
                 "update_goal",
                 %{
                   "goal_id" => "airflow-verification-context",
                   "state" => Enum.at(["working", "waiting", "completed"], index - 1),
                   "detail" => "Inspecting available context and source access."
                 },
                 binding_options(claim)
               )

      replay.(claim, world)
    end

    result =
      WorldRunner.run(scenario,
        api: FakeWorkCoopAPI,
        before_execute: before_execute,
        cassette: cassette,
        client: fake,
        policy: "world-eval-read-only",
        policy_digest: @policy_digest,
        state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
        state_tools_secret: "world-eval-state-tools-secret",
        worker_ref: "world-read-only-plan"
      )

    report =
      case result do
        {:ok, report} -> report
        {:error, {:world_eval_assertions, report}} -> report
      end

    assert report.failures == []
    assert match?({:ok, _}, result)
    assert Enum.count(report.record_history, &(&1["kind"] == "goal_state")) == 5
    assert Repo.query!("SELECT count(*) FROM episode_schedules").rows == [[0]]
  end

  for goal_kind <- ["operation", "schedule"] do
    @effectful_goal_kind goal_kind
    test "source events cannot authorize effectful #{goal_kind} plans or their updates" do
      {:ok, scenario} = WorldCase.fetch("airflow-verification-arms-wait")

      scenario = %{
        scenario
        | world: Map.put(scenario.world, "scheduled_events", []),
          expect: %{"hard" => [], "quality_rubric" => [], "trajectory" => []}
      }

      {:ok, fake} = FakeWorkCoopAPI.start_link([])
      on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)

      before_execute = fn claim, _world ->
        goal =
          Map.merge(recorded_read_only_goal(), %{
            "kind" => @effectful_goal_kind,
            "authority" => "governed_operation",
            "required" => false
          })

        assert {:ok, _} = Tools.call("plan_goal", goal, binding_options(claim))

        assert {:ok, _} =
                 Tools.call(
                   "update_goal",
                   %{"goal_id" => goal["id"], "state" => "working", "detail" => nil},
                   binding_options(claim)
                 )

        {ref, state, message} = record_state_tool!("request_input", claim)
        candidate = final_candidate(state, message, [ref])

        assert {:ok, %{"accepted" => true}} =
                 Tools.call(
                   "validate_final",
                   %{"candidate" => Jason.decode!(candidate)},
                   binding_options(claim)
                 )

        FakeWorkCoopAPI.update(fake, &%{&1 | candidates: [candidate]})
        :ok
      end

      assert {:error, {:world_eval_assertions, report}} =
               WorldRunner.run(scenario,
                 api: FakeWorkCoopAPI,
                 before_execute: before_execute,
                 client: fake,
                 policy: "world-eval-read-only",
                 policy_digest: @policy_digest,
                 state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
                 state_tools_secret: "world-eval-state-tools-secret",
                 worker_ref: "world-source-event-denial"
               )

      assert Enum.sort(Enum.map(report.failures, & &1["record_kind"])) == [
               "goal",
               "goal_state",
               "input_request"
             ]
    end
  end

  test "a source event that does not match the open wait cannot spend another model turn" do
    # The retained production-shaped Terraform replay asked for source_kind=terraform even
    # though both observed inputs arrived through Slack. The old world runner unconditionally
    # resumed that wait, turning an invalid matcher into false-positive end-to-end coverage.
    {:ok, scenario} = WorldCase.fetch("terraform-run-update-stays-in-one-session")

    negative =
      "test/responder/evals/fixtures/terraform_invalid_source_matcher.json"
      |> File.read!()
      |> Jason.decode!()

    scenario = %{scenario | host_replay: negative}
    {:ok, fake} = FakeWorkCoopAPI.start_link([])
    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)
    assert {:ok, before_execute} = WorldHostReplay.before_execute(scenario, fake)

    assert {:error, {:world_eval_assertions, report}} =
             WorldRunner.run(scenario,
               api: FakeWorkCoopAPI,
               before_execute: before_execute,
               client: fake,
               id_generator: fn -> "world-invalid-terraform-wait" end,
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret",
               worker_ref: "world-eval-worker:invalid-terraform-wait"
             )

    # A fresh real-model run hit this same fence and the evaluator erased its
    # accepted candidate, wait and delivery, then mislabeled paid execution "unrun".
    assert report.status == :failed

    assert {:world_eval_failed, {:event_wait_not_matched, wait_ref, input_ref, "slack"}} =
             report.execution_error

    assert [turn] = report.runtime.turns
    assert turn.candidate["outcome"]["state"] == "waiting_for_event"
    assert [%{"ref" => ^wait_ref, "status" => "open"}] = report.records
    assert [_delivery] = report.deliveries

    assert is_binary(wait_ref)
    assert is_binary(input_ref)
    assert FakeWorkCoopAPI.state(fake).submit_count == 1
    refute FakeWorkCoopAPI.state(fake).lost_submit_response
    refute FakeWorkCoopAPI.state(fake).lose_first_submit_response

    assert [%{state: :waiting_for_event, owner_ref: ^wait_ref} = episode] =
             Repo.all(Responder.Episodes.Episode)

    assert length(episode.queued_input_refs) == 1
    assert [%{"ref" => ^wait_ref, "status" => "open"}] = Records.retained_records(episode.id)

    assert :ok =
             WorldRunner.run_cleanup(
               {:error, {:world_eval_assertions, report}},
               &WorldRunner.terminalize_waiting_episodes/0,
               fn ->
                 Repo.delete_all(Turn)
                 :ok
               end
             )

    assert Repo.aggregate(Turn, :count) == 1
    assert Repo.get!(Responder.Episodes.Episode, episode.id).state == :cancelled
    assert turn.candidate["outcome"]["state"] == "waiting_for_event"
    assert [%{"ref" => ^wait_ref, "status" => "open"}] = report.records
  end

  test "a harvested Slack-matched continuation reaches submit-loss reconciliation in the same session" do
    # The earlier Terraform fixture never reached its second-turn loss fault: its
    # matcher named Terraform while the actual source was Slack, falsely earning reconnect credit.
    {:ok, scenario} = WorldCase.fetch("terraform-run-update-stays-in-one-session")
    {:ok, fake} = FakeWorkCoopAPI.start_link([])
    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)
    {:ok, before_execute} = WorldHostReplay.before_execute(scenario, fake)

    assert {:ok, report} =
             WorldRunner.run(scenario,
               api: FakeWorkCoopAPI,
               before_execute: before_execute,
               client: fake,
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret",
               worker_ref: "world-source-matched-reconnect"
             )

    assert report.failures == []
    assert [initial, terminal] = report.runtime.turns
    assert initial.candidate["outcome"]["state"] == "waiting_for_event"
    assert terminal.candidate["outcome"]["state"] == "complete"
    assert terminal.session_id == initial.session_id
    refute terminal.turn_id == initial.turn_id
    assert terminal.input_provenance.source == %{"kind" => "slack", "ref" => "TEVAL"}
    assert terminal.input_provenance.actor_ref == "slack:app:terraform"
    assert report.runtime.skipped_checkpoints == []

    state = FakeWorkCoopAPI.state(fake)
    assert state.lose_first_submit_response
    assert state.lost_submit_response
    assert state.create_count == 1
    assert state.submit_count == 2
    assert length(Enum.uniq(state.turn_keys)) == 2
    [first_key, terminal_key] = state.turn_keys
    assert state.operation_calls[first_key] == 1
    assert state.operation_calls[terminal_key] == 2
    assert length(state.validations) == 2
    assert Enum.all?(state.validations, &(&1.verdict == :accept))
    assert length(Enum.uniq(state.validation_keys)) == 2
    assert Repo.aggregate(Turn, :count) == 2
    assert Enum.all?(Repo.all(Turn), &(&1.status == :settled))

    initial_turn = Repo.get!(Turn, initial.turn_id)
    terminal_turn = Repo.get!(Turn, terminal.turn_id)
    assert terminal_turn.coop_turn_id == state.known_operations[terminal_key]["resource_id"]
    assert terminal_turn.submission["context"]["mode"] == "continuation"

    assert terminal_turn.submission["context"]["parent_submission_ref"] ==
             Submission.fingerprint(initial_turn.submission)

    assert [%{status: :resolved, resolution_kind: :input}] = Repo.all(EventSubscription)

    assert [%{status: :answered, payload: payload}] =
             Repo.all(from(r in Record, where: r.kind == "event_wait"))

    assert payload["event_matcher"]["source_kind"] == "slack"
    assert [%{payload: evidence}] = Repo.all(from(r in Record, where: r.kind == "evidence"))
    assert evidence["source_id"] == terminal.input_provenance.source_ref
    assert [first_delivery, second_delivery] = report.deliveries
    assert first_delivery.target == second_delivery.target
    assert second_delivery.document["message"] == terminal.candidate["message"]
    assert second_delivery.receipt["delivery_ref"] == "delivery:#{terminal.turn_id}"
    assert is_binary(terminal.validation.receipt_sha256)
    assert is_binary(terminal.validation.intent_sha256)

    assert {:ok, coverage} = WorldCoverage.report()
    assert scenario.id in coverage.failure_axes["reconnect"]
  end

  test "historical source timestamps stay consistent with captured evidence and judge inputs" do
    # A paid Airflow run was judged wrong after the harness changed an August 27
    # apply into September 8 but left the source observations and judge on August 27.
    {:ok, scenario} = WorldCase.fetch("airflow-verification-arms-wait")

    fake =
      start_supervised!(%{
        id: FakeWorkCoopAPI,
        start: {FakeWorkCoopAPI, :start_link, [[]]}
      })

    cassette = start_supervised!({WorldCassette, scenario})
    {:ok, before_execute} = WorldHostReplay.before_execute(scenario, fake, cassette: cassette)

    assert {:ok, report} =
             WorldRunner.run(scenario,
               api: FakeWorkCoopAPI,
               before_execute: before_execute,
               cassette: cassette,
               client: fake,
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret"
             )

    [initial | wakeups] = report.runtime.turns
    source_at = hd(scenario.events)["occurred_at"]
    assert {:ok, expected_at, 0} = DateTime.from_iso8601(source_at)
    assert {:ok, actual_at, 0} = DateTime.from_iso8601(initial.input_clock.applied_occurred_at)
    assert DateTime.compare(actual_at, expected_at) == :gt
    assert initial.input_clock.adjustment == "causal_rebase"
    assert initial.input_clock.scenario_occurred_at == source_at

    turn = Repo.get!(Turn, initial.turn_id)
    [submitted] = get_in(turn.submission, ["context", "inputs", "items"])
    envelope = submitted["content"]
    assert envelope["occurred_at_source"] == "ingress"
    clock = envelope["content"]["world_replay_clock"]
    assert clock["source_occurred_at"] == source_at
    assert clock["host_received_at"] == initial.input_clock.applied_occurred_at
    assert clock["scenario_occurred_at_source"] == "source"
    assert Map.delete(envelope["content"], "world_replay_clock") == hd(scenario.events)["payload"]

    assert {:ok, judge} = WorldJudgeCase.new(scenario, report)
    judged = Jason.decode!(judge.prompt)["evidence"]
    assert hd(judged["source_events"])["occurred_at"] == source_at
    assert hd(judged["input_clocks"])["source_occurred_at"] == source_at
    assert hd(judged["input_clocks"])["applied_occurred_at"] == clock["host_received_at"]
    assert judged["source_events"] == scenario.events

    assert Enum.all?(wakeups, fn turn ->
             turn.input_clock.adjustment == "persisted_wait_due_at" and
               turn.input_clock.applied_occurred_at != turn.input_clock.scenario_occurred_at
           end)
  end

  test "a harvested bounded timer resumes through production custody with its actual system identity" do
    # A real Airflow model chose after=10m with a 15-minute deadline. The evaluator
    # required a source-only poll subscription and erased the valid scheduled continuation.
    harvested =
      "test/responder/evals/fixtures/airflow_after_observation_window.json"
      |> File.read!()
      |> Jason.decode!()

    {:ok, scenario} = WorldCase.fetch("airflow-verification-arms-wait")
    scenario = harvested_timer_scenario(scenario, harvested)
    {:ok, fake} = FakeWorkCoopAPI.start_link([])
    {:ok, cassette} = start_supervised({WorldCassette, scenario})
    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)
    {:ok, before_execute} = WorldHostReplay.before_execute(scenario, fake, cassette: cassette)

    assert {:ok, report} =
             WorldRunner.run(scenario,
               api: FakeWorkCoopAPI,
               before_execute: before_execute,
               cassette: cassette,
               client: fake,
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret",
               worker_ref: "world-harvested-timer"
             )

    assert report.failures == []
    assert [initial, timer, fallback] = report.runtime.turns
    assert FakeWorkCoopAPI.state(fake).submit_count == 3
    assert FakeWorkCoopAPI.state(fake).create_count == 1
    assert length(report.deliveries) == 3

    [wait_ref] = initial.candidate["outcome"]["record_refs"]
    record = Repo.get_by!(Record, ref: wait_ref)
    subscription = Repo.get_by!(EventSubscription, record_id: record.id)
    assert record.status == :answered
    assert record.payload["event_matcher"] == harvested["record"]["payload"]["event_matcher"]
    assert subscription.status == :resolved
    assert subscription.resolution_kind == :timer
    assert DateTime.diff(subscription.poll_after, record.inserted_at, :second) == 600
    assert timer.input_clock.adjustment == "persisted_wait_due_at"
    assert timer.input_clock.applied_occurred_at == DateTime.to_iso8601(subscription.poll_after)
    assert timer.input_clock.scenario_occurred_at == "2026-08-27T20:28:13Z"
    assert timer.input_provenance.actor == %{"kind" => "system", "ref" => "event-wait-timer"}
    assert timer.input_provenance.actor_ref == "system:system:event-wait-timer"
    assert timer.input_provenance.source == %{"kind" => "system", "ref" => "responder"}
    assert timer.input_provenance.source_capabilities == %{}
    assert timer.input_provenance.source_item_ref == nil
    assert timer.input_provenance.destination == initial.input_provenance.destination
    assert fallback.input_provenance.actor["ref"] == "event-wait-poll_fallback"

    assert {:ok, :idle} =
             EventWaits.resume_at(record.id, record.episode_id, subscription.poll_after)

    assert Repo.aggregate(Turn, :count) == 3
    assert FakeWorkCoopAPI.state(fake).submit_count == 3
  end

  test "a scheduled checkpoint cannot impersonate a fixture operator even in an uncompiled world" do
    {:ok, scenario} = WorldCase.fetch("airflow-verification-arms-wait")

    scenario = %{
      scenario
      | world:
          Map.put(scenario.world, "scheduled_events", [
            %{
              "kind" => "wait_wakeup",
              "occurred_at" => "2026-08-27T20:28:13Z",
              "actor_ref" => hd(scenario.actors)["actor_ref"]
            }
          ])
    }

    {:ok, fake} = FakeWorkCoopAPI.start_link([])
    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)

    assert {:error, {:invalid_world_runner, :input_actor}} =
             WorldRunner.run(scenario,
               api: FakeWorkCoopAPI,
               client: fake,
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret"
             )

    assert FakeWorkCoopAPI.state(fake).submit_count == 0
    assert Repo.aggregate(Turn, :count) == 0
  end

  test "a settled harvested completion skips remaining wake checkpoints without another model turn" do
    # A paid September 7 Airflow run completed after its real ten-minute timer;
    # demanding the older replay's second wait falsely turned that result into an execution error.
    harvested =
      "test/responder/evals/fixtures/airflow_completes_after_timer.json"
      |> File.read!()
      |> Jason.decode!()

    {:ok, scenario} = WorldCase.fetch("airflow-verification-arms-wait")
    {:ok, fake} = FakeWorkCoopAPI.start_link([])
    {:ok, cassette} = start_supervised({WorldCassette, scenario})
    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)
    before_execute = harvested_completion_replay(harvested, fake, cassette)

    assert {:ok, report} =
             WorldRunner.run(scenario,
               api: FakeWorkCoopAPI,
               before_execute: before_execute,
               cassette: cassette,
               client: fake,
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret",
               worker_ref: "world-harvested-completion"
             )

    assert report.failures == []
    assert report.status == :unrun
    assert report.quality == %{status: :unrun}
    assert [initial, completed] = report.runtime.turns
    assert initial.candidate["outcome"]["state"] == "waiting_for_event"
    assert completed.candidate["outcome"]["state"] == "complete"
    assert completed.candidate["message"] == List.last(harvested["turns"])["candidate"]["message"]
    assert completed.session_id == initial.session_id
    assert completed.input_provenance.actor_ref == "system:system:event-wait-timer"
    assert FakeWorkCoopAPI.state(fake).submit_count == 2
    assert FakeWorkCoopAPI.state(fake).create_count == 1
    assert length(report.deliveries) == 2
    assert Repo.aggregate(Turn, :count) == 2
    # The timer is admitted by the episode transaction, not as a second external inbox receipt.
    assert Repo.aggregate(Responder.Ingress.Inbox.Entry, :count) == 1
    assert Enum.all?(Repo.all(Turn), &(&1.status == :settled))

    assert [%{state: :complete, owner_kind: nil, queued_input_refs: []}] =
             Repo.all(Responder.Episodes.Episode)

    assert [%{status: :answered}] = Repo.all(from(r in Record, where: r.kind == "event_wait"))
    assert [%{status: :resolved, resolution_kind: :timer}] = Repo.all(EventSubscription)

    assert report.runtime.skipped_checkpoints == [
             %{
               after_turn_id: completed.turn_id,
               episode_id: report.episode_id,
               kind: "wait_wakeup",
               reason: "episode_complete",
               scenario_index: 3,
               scenario_occurred_at: "2026-08-27T20:58:15Z"
             }
           ]

    assert {:ok, serialized} =
             report |> Map.merge(%{lane: :candidate, repeat_index: 1}) |> WorldReport.result()

    assert [%{"after_turn_id" => turn_id, "scenario_index" => 3}] =
             serialized["runtime"]["skipped_checkpoints"]

    assert turn_id == completed.turn_id
    assert length(serialized["runtime"]["turns"]) == 2
  end

  test "skipped checkpoints cannot satisfy a required first wait or same-session continuation" do
    {:ok, scenario} = WorldCase.fetch("ordinary-thread-question-gets-natural-answer")

    required = [
      %{"kind" => "state_tool_recorded", "tool" => "wait_for"},
      %{"kind" => "same_session_continuation"}
    ]

    scenario = %{
      scenario
      | world:
          Map.put(scenario.world, "scheduled_events", [
            %{"kind" => "wait_wakeup", "occurred_at" => "2026-08-30T14:10:00Z"}
          ]),
        expect: Map.update!(scenario.expect, "hard", &(&1 ++ required))
    }

    {:ok, fake} = FakeWorkCoopAPI.start_link([])
    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)
    {:ok, before_execute} = WorldHostReplay.before_execute(scenario, fake)

    assert {:error, {:world_eval_assertions, report}} =
             WorldRunner.run(scenario,
               api: FakeWorkCoopAPI,
               before_execute: before_execute,
               client: fake,
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret"
             )

    assert report.failures == required
    refute Map.has_key?(report, :execution_error)
    assert [%{reason: "episode_complete", scenario_index: 2}] = report.runtime.skipped_checkpoints
    assert [_initial] = report.runtime.turns
    assert [_delivery] = report.deliveries
    assert FakeWorkCoopAPI.state(fake).submit_count == 1
    assert Repo.aggregate(Turn, :count) == 1
  end

  for {label, mutation, expected} <- [
        {"missing", :missing, :event_wait_not_due},
        {"inactive", :inactive, :event_wait_already_resumed},
        {"stale", :stale, :event_wait_already_resumed},
        {"expired", :expired, :event_wait_already_resumed},
        {"not-due", :not_due, :event_wait_not_due}
      ] do
    @poll_subscription_label label
    @poll_subscription_mutation mutation
    @poll_subscription_error expected

    test "a #{@poll_subscription_label} wait subscription cannot spend a wakeup model turn" do
      # A valid-looking open event_wait is insufficient timer custody: the exact
      # active subscription and its bounded due window must still authorize the wakeup.
      {:ok, scenario} = WorldCase.fetch("airflow-verification-arms-wait")

      fake =
        start_supervised!(%{
          id: FakeWorkCoopAPI,
          start: {FakeWorkCoopAPI, :start_link, [[]]}
        })

      cassette = start_supervised!({WorldCassette, scenario})

      assert {:ok, before_execute} =
               WorldHostReplay.before_execute(scenario, fake, cassette: cassette)

      result =
        WorldRunner.run(scenario,
          api: FakeWorkCoopAPI,
          before_execute: before_execute,
          before_wait_wakeup: fn _episode, record ->
            poison_poll_subscription!(record.id, @poll_subscription_mutation)
          end,
          cassette: cassette,
          client: fake,
          id_generator: fn -> "world-invalid-poll-#{@poll_subscription_label}" end,
          policy: "world-eval-read-only",
          policy_digest: @policy_digest,
          state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
          state_tools_secret: "world-eval-state-tools-secret",
          worker_ref: "world-eval-worker:invalid-poll-#{@poll_subscription_label}"
        )

      assert [%{state: :waiting_for_event} = episode] = Repo.all(Responder.Episodes.Episode)
      wait_ref = episode.owner_ref
      assert {:error, {:world_eval_assertions, report}} = result
      assert report.status == :failed

      assert {:world_eval_failed, {:wait_wakeup_rejected, ^wait_ref, @poll_subscription_error}} =
               report.execution_error

      assert is_binary(wait_ref)
      assert FakeWorkCoopAPI.state(fake).submit_count == 1
      assert episode.owner_ref == wait_ref
      assert episode.queued_input_refs == []
      assert Repo.aggregate(Turn, :count) == 1
    end
  end

  defp harvested_timer_scenario(scenario, harvested) do
    payload = harvested["record"]["payload"]
    deadline = DateTime.utc_now() |> DateTime.add(900, :second) |> DateTime.to_iso8601()
    captured_clock = String.slice(payload["deadline_at"], 11, 5)
    replay_clock = String.slice(deadline, 11, 5)

    candidate =
      harvested["candidate"]
      |> put_in(["outcome", "record_refs"], ["$call:0:record_ref"])
      |> update_in(["message"], &String.replace(&1, captured_clock, replay_clock))

    call = %{
      "arguments" => %{
        "deadline" => deadline,
        "on_timeout" => payload["event_matcher"]["on_timeout"],
        "trigger" => Map.delete(payload["event_matcher"], "on_timeout"),
        "verification" => payload["verification"]
      },
      "kind" => "state",
      "tool" => "wait_for"
    }

    [first | later] = scenario.host_replay["model_events"]

    first = %{
      first
      | "calls" => [call],
        "candidates" => [%{"document" => candidate, "kind" => "final"}]
    }

    %{
      scenario
      | host_replay: %{"model_events" => [first | later]}
    }
  end

  defp harvested_completion_replay(harvested, fake, cassette) do
    {:ok, counter} = Agent.start_link(fn -> {0, %{}} end)
    on_exit(fn -> if Process.alive?(counter), do: Agent.stop(counter) end)
    deadline = DateTime.utc_now() |> DateTime.add(1_200, :second) |> DateTime.to_iso8601()

    fn claim, _scenario ->
      {index, refs} = Agent.get(counter, & &1)
      captured = Enum.fetch!(harvested["turns"], index)

      for call <- captured["source_calls"] do
        assert {:ok, result} = WorldCassette.call(cassette, call["tool"], call["arguments"])
        assert result == call["result"]
      end

      refs =
        captured["records"]
        |> Enum.with_index()
        |> Enum.reduce(refs, fn {record, offset}, refs ->
          payload = harvested_record_payload(record, refs, deadline)

          assert {:ok, created} =
                   Records.create(
                     Records.token(claim.turn),
                     "captured-#{index}-#{offset}",
                     record["kind"],
                     payload
                   )

          Map.put(refs, record["ref"], created.ref)
        end)

      candidate = replace_harvested_refs(captured["candidate"], refs)

      candidate =
        if index == 0 do
          update_in(
            candidate["message"],
            &String.replace(&1, "13:18", String.slice(deadline, 11, 5))
          )
        else
          candidate
        end

      assert {:ok, %{"accepted" => true}} =
               Tools.call("validate_final", %{"candidate" => candidate}, binding_options(claim))

      FakeWorkCoopAPI.update(fake, &%{&1 | candidates: [Jason.encode!(candidate)]})
      Agent.update(counter, fn _ -> {index + 1, refs} end)
      :ok
    end
  end

  defp harvested_record_payload(%{"kind" => "event_wait", "payload" => payload}, refs, deadline),
    do: payload |> replace_harvested_refs(refs) |> Map.put("deadline_at", deadline)

  defp harvested_record_payload(%{"payload" => payload}, refs, _deadline),
    do: replace_harvested_refs(payload, refs)

  defp replace_harvested_refs(value, refs) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, replace_harvested_refs(item, refs)} end)

  defp replace_harvested_refs(value, refs) when is_list(value),
    do: Enum.map(value, &replace_harvested_refs(&1, refs))

  defp replace_harvested_refs(value, refs), do: Map.get(refs, value, value)

  defp recorded_read_only_goal do
    %{
      "id" => "airflow-verification-context",
      "kind" => "check",
      "authority" => "read_only",
      "requested_outcome" =>
        "Establish available scope and observation-window context for Airflow revision 99183465.",
      "completion_contract" =>
        "Inspect supplied context, available repository documentation, and durable state; record material uncertainties.",
      "parent_goal_id" => nil,
      "prerequisite_goal_ids" => [],
      "read_only_repositories" => [],
      "writable_repository" => nil,
      "required" => true
    }
  end

  test "failed remote cleanup preserves local custody evidence" do
    parent = self()

    assert {:error, {:world_cleanup_blocked, :session_cleanup_error}} =
             WorldRunner.run_cleanup(
               {:ok, %{status: :passed}},
               fn -> {:error, {:world_cleanup_blocked, :session_cleanup_error}} end,
               fn ->
                 send(parent, :local_cleanup_ran)
                 :ok
               end
             )

    refute_received :local_cleanup_ran
  end

  test "successful remote cleanup still reports a local cleanup failure" do
    assert {:error, :local_cleanup_failed} =
             WorldRunner.run_cleanup(
               {:ok, %{status: :passed}},
               fn -> :ok end,
               fn -> {:error, :local_cleanup_failed} end
             )
  end

  test "an executed failure keeps its database evidence even after safe remote cleanup" do
    # The September 7 Terraform world failure destroyed all local evidence after
    # safe remote discard. Only two successful boundaries may authorize truncation.
    parent = self()

    for primary <- [
          {:error, {:world_eval_assertions, %{status: :failed}}},
          {:ok, %{status: :failed}},
          {:ok, %{status: :unrun}}
        ] do
      assert :ok =
               WorldRunner.run_cleanup(
                 primary,
                 fn ->
                   send(parent, :remote_cleanup_ran)
                   :ok
                 end,
                 fn ->
                   send(parent, :local_cleanup_ran)
                   :ok
                 end
               )

      assert_received :remote_cleanup_ran
      refute_received :local_cleanup_ran
    end
  end

  test "successful observation and remote cleanup allow disposable cleanup" do
    parent = self()

    assert :ok =
             WorldRunner.run_cleanup({:ok, %{status: :passed}}, fn -> :ok end, fn ->
               send(parent, :local_cleanup_ran)
               :ok
             end)

    assert_received :local_cleanup_ran
  end

  test "failed cleanup preserves an otherwise successful model report" do
    original = %{
      status: :passed,
      failures: [],
      runtime: %{turns: [%{candidate: %{message: "retained"}}]}
    }

    assert {:error, {:world_eval_assertions, report}} =
             WorldRunner.finish_result({:ok, original}, {:error, :remote_cleanup_failed})

    assert report.status == :failed
    assert report.runtime == original.runtime
    assert report.cleanup_error == :remote_cleanup_failed
    assert report.failures == original.failures
  end

  test "evaluation cleanup retires a final external wait before session retention" do
    episode_id = Ecto.UUID.generate()
    episode_key = "eval:cleanup-wait:#{episode_id}"
    turn_ref = "eval-turn:cleanup-wait:1"

    assert {:ok, _transition} =
             Episodes.apply(%Command.AdmitInput{
               actor_ref: "eval:source",
               destination: %{
                 conversation_ref: "slack:T123:C456",
                 thread_ref: "1788117000.000100",
                 transport: "slack"
               },
               episode_id: episode_id,
               episode_key: episode_key,
               execution_mode: :live,
               native_input_id: "eval-input:cleanup-wait:1",
               occurred_at: ~U[2026-08-30 19:10:00.000000Z],
               payload: %{"text" => "Verify after the observation window."},
               revision: 1,
               turn_ref: turn_ref
             })

    assert {:ok, _transition} =
             Episodes.apply(%Command.StartWait{
               deadline_at: ~U[2026-08-30 19:30:00.000000Z],
               episode_key: episode_key,
               expected_turn_ref: turn_ref,
               kind: :event,
               occurred_at: ~U[2026-08-30 19:10:01.000000Z],
               wait_ref: "eval-wait:cleanup-wait:1"
             })

    assert {:ok, waiting} = Episodes.fetch_by_key(episode_key)
    assert waiting.state == :waiting_for_event

    assert :ok = WorldRunner.terminalize_waiting_episodes()
    assert :ok = WorldRunner.terminalize_waiting_episodes()

    assert {:ok, cancelled} = Episodes.fetch_by_key(episode_key)
    assert cancelled.state == :cancelled
    assert cancelled.owner_kind == nil
    assert cancelled.owner_ref == nil
  end

  for {scenario_id, tool} <- @state_scenarios do
    @scenario_id scenario_id
    @state_tool tool

    test "#{scenario_id} crosses real state custody, final validation, and inert delivery" do
      {:ok, scenario} = WorldCase.fetch(@scenario_id)

      {:ok, fake} =
        FakeWorkCoopAPI.start_link([], companions: scenario_companions(scenario))

      {:ok, turn_counter} = Agent.start_link(fn -> 0 end)
      {:ok, cassette} = start_supervised({WorldCassette, scenario})
      on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)
      on_exit(fn -> if Process.alive?(turn_counter), do: Agent.stop(turn_counter) end)

      before_execute =
        if scenario.host_replay["model_events"] == [] do
          fn claim, _scenario ->
            turn_index = Agent.get_and_update(turn_counter, &{&1 + 1, &1 + 1})

            {state, message, record_refs} =
              if turn_index == 1 do
                {record_ref, state, message} = record_state_tool!(@state_tool, claim)
                {state, message, [record_ref]}
              else
                {"complete", "Applied the new constraint to the same task context.", []}
              end

            candidate = final_candidate(state, message, record_refs)

            assert {:ok, %{"accepted" => true}} =
                     Tools.call(
                       "validate_final",
                       %{"candidate" => Jason.decode!(candidate)},
                       binding_options(claim)
                     )

            FakeWorkCoopAPI.update(fake, &%{&1 | candidates: [candidate]})
            :ok
          end
        else
          assert {:ok, callback} =
                   WorldHostReplay.before_execute(scenario, fake, cassette: cassette)

          callback
        end

      assert {:ok, report} =
               WorldRunner.run(scenario,
                 api: FakeWorkCoopAPI,
                 before_execute: before_execute,
                 cassette: cassette,
                 client: fake,
                 id_generator: fn -> "world-run:#{@scenario_id}" end,
                 policy: "world-eval-read-only",
                 policy_digest: @policy_digest,
                 state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
                 state_tools_secret: "world-eval-state-tools-secret",
                 worker_ref: "world-eval-worker:#{@scenario_id}"
               )

      assert report.failures == []
      assert report.record_history != []

      input_count =
        Enum.count(scenario.events, &(&1["kind"] == "input")) +
          Enum.count(scenario.world["scheduled_events"], &(&1["kind"] == "wait_wakeup"))

      assert length(report.deliveries) == input_count
      assert Enum.all?(report.deliveries, &(&1.target.transport == "slack"))
      assert FakeWorkCoopAPI.state(fake).submit_count == input_count
      assert FakeWorkCoopAPI.state(fake).create_count == 1

      if @scenario_id == "current-uptime-check-uses-fresh-source" do
        assert FakeWorkCoopAPI.state(fake).submit_error_count == 1
        assert FakeWorkCoopAPI.state(fake).submit_count == 1
      end

      turns = Enum.map(report.turn_ids, &Repo.get!(Turn, &1))

      assert Enum.map(turns, &get_in(&1.submission, ["context", "mode"])) ==
               ["full" | List.duplicate("continuation", input_count - 1)]

      assert turns |> Enum.map(& &1.session_id) |> Enum.uniq() |> length() == 1

      if @scenario_id == "airflow-verification-arms-wait" do
        subscriptions =
          Repo.all(
            from(subscription in EventSubscription,
              order_by: [asc: subscription.inserted_at, asc: subscription.id]
            )
          )

        assert length(subscriptions) == 2

        applied_wakeups =
          report.runtime.turns
          |> tl()
          |> Enum.map(fn turn ->
            {:ok, occurred_at, 0} =
              DateTime.from_iso8601(turn.input_clock.applied_occurred_at)

            occurred_at
          end)

        for {subscription, applied_at} <- Enum.zip(subscriptions, applied_wakeups) do
          assert subscription.episode_id == report.episode_id
          assert subscription.status == :resolved
          assert subscription.resolution_kind == :poll_fallback
          assert DateTime.compare(subscription.poll_after, applied_at) == :eq
          assert DateTime.compare(applied_at, subscription.deadline_at) == :lt
        end

        for turn <- tl(report.runtime.turns) do
          assert turn.input_clock.adjustment == "persisted_wait_due_at"
          assert turn.routing.mode == "forced_host_scenario"
          assert turn.routing.action == "continue_episode"
          assert turn.routing.relation == "same_work"

          assert turn.input_provenance.actor == %{
                   "kind" => "system",
                   "ref" => "event-wait-poll_fallback"
                 }

          assert turn.input_provenance.source == %{"kind" => "system", "ref" => "responder"}
          assert turn.input_provenance.source_capabilities == %{}
          assert turn.input_provenance.source_item_ref == nil
        end
      end

      if @scenario_id == "current-uptime-check-uses-fresh-source" do
        assert [turn] = turns
        assert turn.work_attempt_count == 2
      end

      turns
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [parent, continuation] ->
        assert get_in(continuation.submission, ["context", "parent_submission_ref"]) ==
                 Submission.fingerprint(parent.submission)
      end)
    end
  end

  test "an explicit operator incident request may create one confirmable incident offer" do
    {:ok, scenario} = WorldCase.fetch("explicit-operator-incident-offer")
    {:ok, fake} = FakeWorkCoopAPI.start_link([])
    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)

    before_execute = fn claim, _scenario ->
      {record_ref, state, message} = record_incident_task_tool!(claim)
      candidate = final_candidate(state, message, [record_ref])

      assert {:ok, %{"accepted" => true}} =
               Tools.call(
                 "validate_final",
                 %{"candidate" => Jason.decode!(candidate)},
                 binding_options(claim)
               )

      FakeWorkCoopAPI.update(fake, &%{&1 | candidates: [candidate]})
      :ok
    end

    assert {:ok, report} =
             WorldRunner.run(scenario,
               api: FakeWorkCoopAPI,
               before_execute: before_execute,
               client: fake,
               id_generator: fn -> "world-explicit-operator-incident" end,
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret",
               worker_ref: "world-eval-worker:explicit-operator-incident"
             )

    assert report.failures == []

    assert [
             %{
               "kind" => "task_offer",
               "payload" => %{"kind" => "incident", "repository" => nil},
               "status" => "open"
             }
           ] = report.records
  end

  test "later repository feedback replaces the pending task offer instead of creating another task" do
    {:ok, scenario} = WorldCase.fetch("rivals-engineering-task-offer")
    {:ok, fake} = FakeWorkCoopAPI.start_link([], companions: scenario_companions(scenario))
    {:ok, turn_state} = Agent.start_link(fn -> %{index: 0, record_ref: nil} end)
    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)
    on_exit(fn -> if Process.alive?(turn_state), do: Agent.stop(turn_state) end)

    prompts = [
      "Add bounded context to Rivals Gate timeout logs.",
      "Also aggregate failures by bounded request parameters.",
      "Use fixed five-minute aggregation windows."
    ]

    before_execute = fn claim, _scenario ->
      %{index: index, record_ref: prior_record_ref} = Agent.get(turn_state, & &1)

      instruction_ref = prior_record_ref || "slack:TEVAL:CEVAL:1788019200.000100"

      assert {:ok, %{"record_ref" => record_ref}} =
               Tools.call(
                 "request_task",
                 %{
                   "authority_limits" => ["do not deploy or publish"],
                   "instruction_ref" => instruction_ref,
                   "prompt" => Enum.at(prompts, index),
                   "repository" => "blitz-rivals-scraper",
                   "source_refs" => [],
                   "success_checks" => ["focused repository tests pass"],
                   "title" => "Improve Rivals Gate timeout observability"
                 },
                 binding_options(claim)
               )

      Agent.update(turn_state, &%{&1 | index: index + 1, record_ref: record_ref})

      candidate =
        final_candidate(
          "complete",
          "Updated the one pending Rivals engineering task.",
          [record_ref]
        )

      assert {:ok, %{"accepted" => true}} =
               Tools.call(
                 "validate_final",
                 %{"candidate" => Jason.decode!(candidate)},
                 binding_options(claim)
               )

      FakeWorkCoopAPI.update(fake, &%{&1 | candidates: [candidate]})
      :ok
    end

    assert {:ok, report} =
             WorldRunner.run(scenario,
               api: FakeWorkCoopAPI,
               before_execute: before_execute,
               client: fake,
               id_generator: fn -> "world-task-feedback-replaces" end,
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret",
               worker_ref: "world-eval-worker:task-feedback"
             )

    assert report.failures == []
    assert [%{"kind" => "task_offer", "payload" => payload, "status" => "open"}] = report.records

    assert payload["prompt"] ==
             List.last(prompts) <>
               "\n\nSuccess checks: focused repository tests pass\n\nAuthority limits: do not deploy or publish\n\nInstruction: slack:TEVAL:CEVAL:1788019200.000100\n\nSources: "

    assert Enum.map(report.record_history, & &1["status"]) == [
             "superseded",
             "superseded",
             "open"
           ]
  end

  for {scenario_id, transport} <- @platform_scenarios do
    @scenario_id scenario_id
    @transport transport

    test "#{scenario_id} replays through the normalized platform destination" do
      {:ok, scenario} = WorldCase.fetch(@scenario_id)
      {:ok, fake} = FakeWorkCoopAPI.start_link([])
      on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)
      assert {:ok, before_execute} = WorldHostReplay.before_execute(scenario, fake)

      assert {:ok, report} =
               WorldRunner.run(scenario,
                 api: FakeWorkCoopAPI,
                 before_execute: before_execute,
                 client: fake,
                 id_generator: fn -> "world-run:#{@scenario_id}" end,
                 policy: "world-eval-read-only",
                 policy_digest: @policy_digest,
                 state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
                 state_tools_secret: "world-eval-state-tools-secret",
                 worker_ref: "world-eval-worker:#{@scenario_id}"
               )

      assert report.failures == []
      assert [%{target: %{transport: @transport}}] = report.deliveries
      assert FakeWorkCoopAPI.state(fake).submit_count == 1

      if @scenario_id == "github-pr-review-remains-in-thread" do
        assert [turn] = report.runtime.turns

        assert turn.input_provenance.source_item_ref ==
                 "github:pull_request_review_comment:9003"

        assert turn.input_provenance.source == %{"kind" => "github", "ref" => "eval"}
      end
    end
  end

  for scenario_id <- @core_host_scenarios do
    @scenario_id scenario_id

    test "#{scenario_id} replays the complete host journey without a model" do
      {:ok, scenario} = WorldCase.fetch(@scenario_id)
      {:ok, fake} = FakeWorkCoopAPI.start_link([])
      on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)

      cassette =
        if scenario.world["tool_rules"] == [] do
          nil
        else
          {:ok, cassette} = start_supervised({WorldCassette, scenario})
          cassette
        end

      assert {:ok, before_execute} =
               WorldHostReplay.before_execute(scenario, fake, cassette: cassette)

      assert {:ok, report} =
               WorldRunner.run(scenario,
                 api: FakeWorkCoopAPI,
                 before_execute: before_execute,
                 cassette: cassette,
                 client: fake,
                 id_generator: fn -> "world-run:#{@scenario_id}" end,
                 policy: "world-eval-read-only",
                 policy_digest: @policy_digest,
                 state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
                 state_tools_secret: "world-eval-state-tools-secret",
                 worker_ref: "world-eval-worker:#{@scenario_id}"
               )

      input_count =
        Enum.count(scenario.events, &(&1["kind"] == "input")) +
          Enum.count(scenario.world["scheduled_events"], &(&1["kind"] == "wait_wakeup"))

      assert report.failures == []
      assert length(report.deliveries) == input_count

      expected_transport =
        if @scenario_id == "artifact-delivery-survives-work-handoff",
          do: "control_plane",
          else: "slack"

      assert Enum.all?(report.deliveries, &(&1.target.transport == expected_transport))
      assert FakeWorkCoopAPI.state(fake).submit_count == input_count
      assert FakeWorkCoopAPI.state(fake).create_count == 1

      assert Enum.map(report.runtime.turns, & &1.input_clock.scenario_occurred_at) ==
               Enum.map(
                 Enum.filter(scenario.events, &(&1["kind"] == "input")) ++
                   scenario.world["scheduled_events"],
                 & &1["occurred_at"]
               )

      assert Enum.all?(report.runtime.turns, fn turn ->
               turn.input_clock.mode == "simulated" and
                 match?(
                   {:ok, _datetime, 0},
                   DateTime.from_iso8601(turn.input_clock.applied_occurred_at)
                 ) and turn.routing.mode == "forced_host_scenario" and
                 turn.routing.action in ~w(start_episode continue_episode) and
                 turn.routing.relation in ~w(unrelated same_work) and
                 is_binary(turn.routing.reason) and is_map(turn.input_provenance.actor) and
                 is_map(turn.input_provenance.source) and
                 is_map(turn.input_provenance.destination)
             end)

      turns = Enum.map(report.turn_ids, &Repo.get!(Turn, &1))
      assert turns |> Enum.map(& &1.session_id) |> Enum.uniq() |> length() == 1

      if @scenario_id == "artifact-delivery-survives-work-handoff" do
        assert [delivery] = report.deliveries
        assert delivery.attempts == 2

        assert [
                 %{
                   bytes: 82_746,
                   media_type: "image/png",
                   name: "synthetic-request-rate.png",
                   ref: "artifact_65115459af7411aa45ed1400",
                   sha256: "65115459af7411aa45ed14005ba85d13c08f89b7526f29029d1b13532018f966"
                 }
               ] = delivery.artifacts

        assert {:ok, [stored]} =
                 Outputs.fetch_many(report.turn_id, ["artifact_65115459af7411aa45ed1400"])

        harvested = hd(scenario.host_replay["model_events"])["output_artifacts"] |> hd()
        assert stored.data == Base.decode64!(harvested["data_base64"])
        assert binary_part(stored.data, 0, 8) == <<137, 80, 78, 71, 13, 10, 26, 10>>
        [turn] = turns
        [input] = get_in(turn.submission, ["context", "inputs", "items"])
        envelope = input["content"]

        assert Map.delete(envelope["content"], "world_replay_clock") ==
                 hd(scenario.events)["payload"]

        assert envelope["content"]["world_replay_clock"]["source_occurred_at"] == nil

        assert envelope["content"]["world_replay_clock"]["scenario_occurred_at_source"] ==
                 "ingress"

        assert envelope["destination"] == hd(scenario.events)["destination"]
        assert envelope["source"] == %{"kind" => "control_plane", "ref" => "local"}

        assert envelope["content"]["text"] =~
                 "Mon 12, Tue 18, Wed 15, Thu 22, Fri 20, Sat 10, Sun 14"

        assert envelope["content"]["text"] =~ "Do not send any Slack posts"
      end

      if @scenario_id == "noisy-context-keeps-current-request" do
        [turn] = turns
        [current] = get_in(turn.submission, ["context", "inputs", "items"])
        envelope = current["content"]

        assert envelope["content"]["text"] =~ "current-request-7f3a"
        assert length(envelope["content"]["nearby_context"]) == 20

        assert get_in(report.deliveries, [Access.at(0), :document, "message"]) =~
                 "current-request-7f3a"
      end

      if @scenario_id == "va1-health-review-repairs-and-finishes" do
        [turn] = turns

        assert MapSet.new(get_in(turn.submission, ["context", "source_and_action_tools"])) ==
                 MapSet.new(~w(monitoring.query nomad.deployments nomad.service_health))
      end
    end
  end

  test "runner freezes the exact fabricated source-tool catalog into the model briefing" do
    {:ok, scenario} = WorldCase.fetch("va1-health-review-repairs-and-finishes")

    tool_catalog =
      Map.update!(scenario.tool_catalog, "servers", fn servers ->
        Enum.map(servers, fn
          %{"name" => "fabricated-world", "tools" => tools} = server ->
            Map.put(server, "tools", tools ++ [eval_only_source_tool()])

          server ->
            server
        end)
      end)

    scenario = %{scenario | tool_catalog: tool_catalog}
    {:ok, fake} = FakeWorkCoopAPI.start_link([])
    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)
    {:ok, cassette} = start_supervised({WorldCassette, scenario})

    assert {:ok, before_execute} =
             WorldHostReplay.before_execute(scenario, fake, cassette: cassette)

    assert {:ok, report} =
             WorldRunner.run(scenario,
               api: FakeWorkCoopAPI,
               before_execute: before_execute,
               cassette: cassette,
               client: fake,
               id_generator: fn -> "world-run:exact-source-tools" end,
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret",
               worker_ref: "world-eval-worker:exact-source-tools"
             )

    [turn_id] = report.turn_ids
    turn = Repo.get!(Turn, turn_id)

    assert "eval.only" in get_in(turn.submission, ["context", "source_and_action_tools"])
  end

  test "live model artifact proof accepts any real generated image without weakening exact host replay" do
    {:ok, scenario} = WorldCase.fetch("artifact-delivery-survives-work-handoff")
    {:ok, fake} = FakeWorkCoopAPI.start_link([])
    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)

    data = <<137, 80, 78, 71, 13, 10, 26, 10, "live-generated-chart">>
    digest = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
    ref = "artifact_#{String.slice(digest, 0, 24)}"
    [event] = scenario.host_replay["model_events"]

    event =
      event
      |> put_in(
        ["candidates", Access.at(0), "document", "outcome", "artifact_refs"],
        [ref]
      )
      |> Map.put("output_artifacts", [
        %{
          "bytes" => byte_size(data),
          "data_base64" => Base.encode64(data),
          "id" => ref,
          "media_type" => "image/png",
          "name" => "model-selected-name.png",
          "sha256" => digest
        }
      ])

    scenario = %{scenario | host_replay: %{"model_events" => [event]}}
    assert {:ok, before_execute} = WorldHostReplay.before_execute(scenario, fake)

    assert {:ok, report} =
             WorldRunner.run(scenario,
               api: FakeWorkCoopAPI,
               before_execute: before_execute,
               client: fake,
               expectation_mode: :model_world,
               id_generator: fn -> "world-model-artifact" end,
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret",
               worker_ref: "world-model-artifact-worker"
             )

    assert [%{artifacts: [%{ref: ^ref, sha256: ^digest}]}] = report.deliveries
  end

  test "worker loss after remote submit is reconciled by a replacement process without a second turn" do
    {:ok, scenario} = WorldCase.fetch("worker-loss-reconciles-frozen-turn")
    input = hd(scenario.events)
    {:ok, occurred_at, 0} = DateTime.from_iso8601(input["occurred_at"])
    episode_id = Ecto.UUID.generate()

    destination = %{
      conversation_ref: input["destination"]["conversation_ref"],
      thread_ref: input["destination"]["thread_ref"],
      transport: input["destination"]["transport"]
    }

    assert {:ok, transition} =
             Episodes.apply(%Command.AdmitInput{
               actor_ref: input["actor_ref"],
               destination: destination,
               episode_id: episode_id,
               episode_key: "eval:worker-loss:#{episode_id}",
               execution_mode: :live,
               native_input_id: "eval-input:worker-loss:1",
               occurred_at: occurred_at,
               payload: input["payload"],
               revision: 1,
               turn_ref: "eval-turn:worker-loss:1"
             })

    assert {:ok, _session} =
             Custody.pin_episode(
               transition.episode.id,
               "world-eval-read-only",
               @policy_digest,
               nil
             )

    assert {:ok, claim} = Custody.claim_next("world-worker:lost", 300, :work)
    {:ok, fake} = FakeWorkCoopAPI.start_link([], pause_after_submit: self())
    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)
    assert {:ok, before_execute} = WorldHostReplay.before_execute(scenario, fake)
    assert :ok = before_execute.(claim, scenario)

    {lost_worker, monitor} =
      spawn_monitor(fn ->
        WorkDispatcher.run_claim(claim, work_dispatcher_options(fake, "lost"))
      end)

    assert_receive {:fake_work_submit_committed, ^lost_worker}, 2_000
    Process.exit(lost_worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^lost_worker, :killed}, 2_000

    Repo.update_all(
      from(turn in Turn, where: turn.id == ^claim.turn.id),
      set: [lease_expires_at: ~U[2000-01-01 00:00:00.000000Z]]
    )

    assert {:ok, replacement} = Custody.claim_next("world-worker:replacement", 300, :work)
    assert replacement.turn.id == claim.turn.id
    assert replacement.turn.lease_owner == "world-worker:replacement"

    assert {:ok, {:executed, execution}} =
             WorkDispatcher.run_claim(
               replacement,
               work_dispatcher_options(fake, "replacement")
             )

    assert execution.turn.status == :delivery_pending

    {:ok, delivery_agent} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(delivery_agent), do: Agent.stop(delivery_agent) end)

    assert {:ok, adapters} =
             Adapters.new(%{
               "slack" => %{
                 binding: delivery_agent,
                 message_publisher: SlackDeliveryPublisher,
                 reaction_publisher: SlackDeliveryPublisher
               }
             })

    assert {:ok, {:delivered, :message, delivery_ref}} =
             DeliveryDispatcher.run_once(
               adapters: adapters,
               kind: :message,
               lease_seconds: 60,
               max_attempts: 1,
               retry_base_seconds: 1,
               retry_max_seconds: 1,
               worker_ref: "world-worker:delivery"
             )

    assert [{:message, request, receipt}] = Agent.get(delivery_agent, & &1)
    assert request.ref == delivery_ref
    assert receipt["delivery_ref"] == delivery_ref
    assert request.document["message"] == "Your request was received."

    fake_state = FakeWorkCoopAPI.state(fake)
    assert fake_state.submit_count == 1
    assert length(fake_state.submissions) == 1
    assert Enum.map(fake_state.validations, & &1.verdict) == [:accept]
  end

  test "one fabricated world uses real state records, same-turn repair, and inert delivery" do
    {:ok, scenario} = WorldCase.fetch("va1-health-review-repairs-and-finishes")
    {:ok, cassette} = start_supervised({WorldCassette, scenario})

    {:ok, fake} =
      FakeWorkCoopAPI.start_link([],
        session_target: "codex:gpt-5.6-sol/high@world-eval",
        turn_finished_at: "2026-08-15T15:04:10.000000Z",
        turn_queued_at: "2026-08-15T15:00:02.000000Z",
        turn_started_at: "2026-08-15T15:00:04.000000Z",
        turn_usage: %{
          "cached_input_tokens" => 1_200,
          "cost_recorded" => true,
          "cost_usd" => 0.42,
          "input_tokens" => 2_400,
          "output_tokens" => 320,
          "reasoning_tokens" => 180
        }
      )

    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)

    before_execute = successful_before_execute(scenario, fake, cassette)

    assert {:ok, report} =
             WorldRunner.run(scenario,
               api: FakeWorkCoopAPI,
               before_execute: before_execute,
               cassette: cassette,
               client: fake,
               id_generator: fn -> "world-run" end,
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret",
               worker_ref: "world-eval-worker"
             )

    assert report.status == :unrun
    assert report.quality == %{status: :unrun}
    assert [%{"kind" => "evidence"}] = report.records
    assert [%{target: %{transport: "slack"}}] = report.deliveries
    assert length(report.source_calls) == 2

    tool_catalog_digest = scenario.tool_catalog_digest

    assert %{
             policy: "world-eval-read-only",
             policy_digest: @policy_digest,
             tool_catalog_sha256: ^tool_catalog_digest,
             turns: [
               %{
                 candidate_attempt: 2,
                 cost_recorded: true,
                 cost_usd: "0.42",
                 effort: "high",
                 host_ms: host_ms,
                 input_tokens: 2_400,
                 cached_input_tokens: 1_200,
                 model: "gpt-5.6-sol",
                 output_tokens: 320,
                 prompt_sha256: prompt_sha256,
                 provider: "codex",
                 provider_ms: 246_000,
                 queued_ms: 2_000,
                 reasoning_tokens: 180,
                 session_id: session_id,
                 turn_id: turn_id
               }
             ]
           } = report.runtime

    assert prompt_sha256 =~ ~r/\A[0-9a-f]{64}\z/
    assert is_integer(host_ms) and host_ms >= 0
    assert is_binary(session_id)
    assert is_binary(turn_id)

    assert [turn_evidence] = report.runtime.turns
    assert turn_evidence.candidate_attempt == 2
    assert turn_evidence.candidate_sha256 =~ ~r/\A[0-9a-f]{64}\z/
    assert turn_evidence.repair_count == 1
    assert turn_evidence.validation.verdict == "accept"
    assert get_in(turn_evidence.candidate, ["outcome", "state"]) == "complete"

    state = FakeWorkCoopAPI.state(fake)
    assert state.submit_count == 1
    assert Enum.map(state.validations, & &1.verdict) == [:reject, :accept]
  end

  test "a fabricated world preserves the normalized platform destination" do
    {:ok, scenario} = WorldCase.fetch("va1-health-review-repairs-and-finishes")
    {:ok, cassette} = start_supervised({WorldCassette, scenario})
    {:ok, fake} = FakeWorkCoopAPI.start_link([])
    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)

    destination = %{
      "conversation_ref" => "github:eval:repository:99",
      "thread_ref" => "github:eval:pull:42",
      "transport" => "github"
    }

    scenario = %{
      scenario
      | events: [scenario.events |> hd() |> Map.put("destination", destination)]
    }

    assert {:ok, report} =
             WorldRunner.run(scenario,
               api: FakeWorkCoopAPI,
               before_execute: successful_before_execute(scenario, fake, cassette),
               cassette: cassette,
               client: fake,
               id_generator: fn -> "world-github-destination" end,
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret",
               worker_ref: "world-eval-github"
             )

    assert [%{target: target}] = report.deliveries

    assert target == %{
             conversation_ref: destination["conversation_ref"],
             thread_ref: destination["thread_ref"],
             transport: "github"
           }
  end

  test "a fabricated world records a model judge decision separately from host assertions" do
    {:ok, scenario} = WorldCase.fetch("va1-health-review-repairs-and-finishes")
    {:ok, cassette} = start_supervised({WorldCassette, scenario})
    {:ok, fake} = FakeWorkCoopAPI.start_link([])
    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)

    judge = fn judged_scenario, report ->
      assert judged_scenario.id == scenario.id
      assert report.failures == []
      {:ok, %{decision: :accept, reason: "trajectory is grounded", status: :passed}}
    end

    assert {:ok, report} =
             WorldRunner.run(scenario,
               api: FakeWorkCoopAPI,
               before_execute: successful_before_execute(scenario, fake, cassette),
               cassette: cassette,
               client: fake,
               id_generator: fn -> "world-judged" end,
               judge: judge,
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret",
               worker_ref: "world-eval-worker"
             )

    assert report.status == :passed

    assert report.quality == %{
             decision: :accept,
             reason: "trajectory is grounded",
             status: :passed
           }
  end

  for {name, judge_result, expected} <- [
        {"typed judge failure", {:error, :judge_unavailable},
         {:error, {:world_eval_judge, :judge_unavailable}}},
        {"malformed judge result", :malformed,
         {:error, {:world_eval_judge, {:invalid_result, :malformed}}}}
      ] do
    @judge_result judge_result
    @expected_judge_result expected

    test "#{name} fails the world without weakening host assertions" do
      {:ok, scenario} = WorldCase.fetch("va1-health-review-repairs-and-finishes")
      {:ok, cassette} = start_supervised({WorldCassette, scenario})
      {:ok, fake} = FakeWorkCoopAPI.start_link([])
      on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)

      assert {:error, {:world_eval_assertions, report}} =
               WorldRunner.run(scenario,
                 api: FakeWorkCoopAPI,
                 before_execute: successful_before_execute(scenario, fake, cassette),
                 cassette: cassette,
                 client: fake,
                 id_generator: fn -> "world-judge-failure" end,
                 judge: fn _scenario, _report -> @judge_result end,
                 policy: "world-eval-read-only",
                 policy_digest: @policy_digest,
                 state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
                 state_tools_secret: "world-eval-state-tools-secret",
                 worker_ref: "world-eval-worker"
               )

      assert report.status == :failed
      assert {:error, report.execution_error} == @expected_judge_result
      assert report.runtime.turns != []
      assert report.deliveries != []
    end
  end

  test "host assertions fail a fabricated world before model judging" do
    {:ok, scenario} = WorldCase.fetch("va1-health-review-repairs-and-finishes")

    additional_hard =
      for tool <- ~w(
            record_coverage
            record_finding
            report_progress
            plan_goal
            update_goal
            record_alert_assessment
            offer_task
            request_input
            record_evidence
            record_feedback
            unknown_tool
          ) do
        %{"kind" => "state_tool_recorded", "tool" => tool}
      end

    scenario =
      %{
        scenario
        | expect:
            scenario.expect
            |> Map.update!("hard", &(&1 ++ additional_hard ++ [%{"kind" => "unknown_hard"}]))
            |> Map.update!("trajectory", fn trajectory ->
              trajectory ++
                [
                  %{
                    "arguments" => %{"environment" => "missing"},
                    "kind" => "required_tool_result",
                    "result" => %{"state" => "missing"},
                    "tool" => "monitoring.query"
                  },
                  %{"kind" => "unknown_trajectory"}
                ]
            end)
      }

    {:ok, fake} = FakeWorkCoopAPI.start_link([])
    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)

    before_execute = fn claim, _scenario ->
      candidate =
        Jason.encode!(%{
          "decision_reason" => nil,
          "delivery" => "reply",
          "message" => "Everything is healthy.",
          "outcome" => %{
            "artifact_refs" => [],
            "record_refs" => [],
            "state" => "complete"
          }
        })

      binding = %{
        binding: %{
          episode: claim.episode,
          session: claim.session,
          state_token: Records.token(claim.turn),
          turn: claim.turn
        }
      }

      assert {:ok, %{"accepted" => true}} =
               Tools.call(
                 "validate_final",
                 %{"candidate" => Jason.decode!(candidate)},
                 binding
               )

      FakeWorkCoopAPI.update(fake, &%{&1 | candidates: [candidate]})
      :ok
    end

    assert {:error, {:world_eval_assertions, report}} =
             WorldRunner.run(scenario,
               api: FakeWorkCoopAPI,
               before_execute: before_execute,
               client: fake,
               id_generator: fn -> "world-host-failure" end,
               judge: fn _scenario, _report ->
                 flunk("judge must not run after a host failure")
               end,
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret",
               worker_ref: "world-eval-worker"
             )

    assert report.status == :failed
    assert Enum.any?(report.failures, &(&1["kind"] == "state_tool_recorded"))
    assert Enum.any?(report.failures, &(&1["kind"] == "required_tool_call"))

    assert Enum.any?(report.failures, fn failure ->
             failure["kind"] == "required_tool_result" and
               not Map.has_key?(failure, "error")
           end)

    assert Enum.any?(report.failures, &(&1["error"] == "unknown_hard_assertion"))
    assert Enum.any?(report.failures, &(&1["error"] == "unknown_trajectory_assertion"))
  end

  test "runner inputs and settings fail closed before touching the database" do
    {:ok, scenario} = WorldCase.fetch("va1-health-review-repairs-and-finishes")

    assert {:error, {:invalid_world_runner, :scenario}} = WorldRunner.run(%{}, [])
    assert {:error, {:invalid_world_runner, :options}} = WorldRunner.run(scenario, nil)

    assert {:error, {:invalid_world_runner, :options}} =
             WorldRunner.run(scenario, client: :client, client: :duplicate)

    assert {:error, {:invalid_world_runner, :options}} =
             WorldRunner.run(scenario,
               api: FakeWorkCoopAPI,
               cleanup_remote: :invalid,
               client: self(),
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret"
             )

    assert {:error, {:invalid_world_runner, :options}} =
             WorldRunner.run(scenario,
               api: FakeWorkCoopAPI,
               client: self(),
               policy: "world-eval-read-only",
               policy_digest: "not-a-digest",
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret"
             )

    assert {:error, :model_world_database_not_disposable} =
             WorldRunner.run(scenario,
               api: FakeWorkCoopAPI,
               cleanup: true,
               client: self(),
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret"
             )

    scenario_without_input =
      %{scenario | events: Enum.reject(scenario.events, &(&1["kind"] == "input"))}

    assert {:error, {:invalid_world_runner, :initial_input}} =
             WorldRunner.run(scenario_without_input,
               api: FakeWorkCoopAPI,
               client: self(),
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret"
             )

    scenario_with_unknown_actor =
      update_in(scenario.events, fn events ->
        Enum.map(events, fn
          %{"kind" => "input"} = event -> Map.put(event, "actor_ref", "slack:user:unknown")
          event -> event
        end)
      end)

    assert {:error, {:invalid_world_runner, :input_actor}} =
             WorldRunner.run(scenario_with_unknown_actor,
               api: FakeWorkCoopAPI,
               client: self(),
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret"
             )

    assert Repo.aggregate(Responder.Episodes.Episode, :count) == 0
  end

  test "runner refuses a database with durable non-episode application state" do
    {:ok, scenario} = WorldCase.fetch("va1-health-review-repairs-and-finishes")
    now = DateTime.utc_now()

    Repo.insert_all(ChannelConfiguration, [
      %{
        id: Ecto.UUID.generate(),
        actor_ref: "slack:user:U-operator",
        alert_policy: :reply,
        channel_ref: "C-eval-safety",
        inserted_at: now,
        invite_user_group_refs: [],
        invite_user_refs: [],
        participation: :mentions,
        repository_ref: "responder",
        revision: 1,
        saved_at: now,
        updated_at: now,
        workspace_ref: "T-eval-safety"
      }
    ])

    assert {:error, :model_world_requires_an_empty_disposable_database} =
             WorldRunner.run(scenario,
               api: FakeWorkCoopAPI,
               client: self(),
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret"
             )

    assert Repo.aggregate(Responder.Episodes.Episode, :count) == 0
  end

  test "repository feedback may ask one bounded clarification without gaining write authority" do
    {:ok, scenario} = WorldCase.fetch("github-pr-review-remains-in-thread")
    {:ok, fake} = FakeWorkCoopAPI.start_link([])
    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)

    before_execute = fn claim, _scenario ->
      {record_ref, state, message} = record_state_tool!("request_input", claim)
      candidate = final_candidate(state, message, [record_ref])

      assert {:ok, %{"accepted" => true}} =
               Tools.call(
                 "validate_final",
                 %{"candidate" => Jason.decode!(candidate)},
                 binding_options(claim)
               )

      FakeWorkCoopAPI.update(fake, &%{&1 | candidates: [candidate]})
      :ok
    end

    assert {:ok, report} =
             WorldRunner.run(scenario,
               api: FakeWorkCoopAPI,
               before_execute: before_execute,
               client: fake,
               id_generator: fn -> "world-repository-feedback-question" end,
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret",
               worker_ref: "world-eval-worker:repository-feedback-question"
             )

    assert report.failures == []
    assert [%{"kind" => "input_request", "status" => "open"}] = report.records
    assert [%{target: %{transport: "github"}}] = report.deliveries
  end

  test "repository write offer may preserve its instruction as evidence" do
    # Two candidate observations in the full paired world gate completed valid task offers but
    # failed the hard-authority check after citing the human instruction that authorized them.
    {:ok, scenario} = WorldCase.fetch("concurrent-human-feedback-serializes")

    scenario = %{
      scenario
      | events: Enum.take(scenario.events, 1),
        expect: %{"hard" => [], "quality_rubric" => [], "trajectory" => []}
    }

    {:ok, fake} = FakeWorkCoopAPI.start_link([])
    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)

    before_execute = fn claim, _scenario ->
      assert {:ok, %{"record_ref" => evidence_ref}} =
               Tools.call(
                 "cite_source",
                 %{
                   "observation" =>
                     "The authorized request is to add bounded context to Rivals Gate timeout logs.",
                   "relation" => "supports",
                   "source_ref" => "admit_input:repository-write-offer",
                   "subject" => "Requested engineering change",
                   "supersedes" => []
                 },
                 binding_options(claim)
               )

      {task_ref, state, message} = record_state_tool!("request_task", claim)
      candidate = final_candidate(state, message, [evidence_ref, task_ref])

      assert {:ok, %{"accepted" => true}} =
               Tools.call(
                 "validate_final",
                 %{"candidate" => Jason.decode!(candidate)},
                 binding_options(claim)
               )

      FakeWorkCoopAPI.update(fake, &%{&1 | candidates: [candidate]})
      :ok
    end

    assert {:ok, report} =
             WorldRunner.run(scenario,
               api: FakeWorkCoopAPI,
               before_execute: before_execute,
               client: fake,
               id_generator: fn -> "world-repository-write-offer-evidence" end,
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret",
               worker_ref: "world-eval-worker:repository-write-offer-evidence"
             )

    assert report.failures == []
    assert report.records |> Enum.map(& &1["kind"]) |> Enum.sort() == ["evidence", "task_offer"]
  end

  test "actor authority rejects a durable state action outside the fabricated world" do
    {:ok, scenario} = WorldCase.fetch("va1-health-review-repairs-and-finishes")

    scenario = %{
      scenario
      | events: Enum.filter(scenario.events, &(&1["kind"] == "input")),
        expect: %{"hard" => [], "quality_rubric" => [], "trajectory" => []}
    }

    {:ok, fake} = FakeWorkCoopAPI.start_link([])
    on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)

    before_execute = fn claim, _scenario ->
      {record_ref, state, message} = record_state_tool!("request_task", claim)
      candidate = final_candidate(state, message, [record_ref])

      assert {:ok, %{"accepted" => true}} =
               Tools.call(
                 "validate_final",
                 %{"candidate" => Jason.decode!(candidate)},
                 binding_options(claim)
               )

      FakeWorkCoopAPI.update(fake, &%{&1 | candidates: [candidate]})
      :ok
    end

    assert {:error, {:world_eval_assertions, report}} =
             WorldRunner.run(scenario,
               api: FakeWorkCoopAPI,
               before_execute: before_execute,
               client: fake,
               id_generator: fn -> "world-unauthorized-action" end,
               policy: "world-eval-read-only",
               policy_digest: @policy_digest,
               state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
               state_tools_secret: "world-eval-state-tools-secret",
               worker_ref: "world-eval-worker"
             )

    assert [failure] = report.failures
    assert failure["kind"] == "unauthorized_state_record"
    assert failure["actor_ref"] == "schedule:system:schedule"
    assert failure["authority"] == "read_only"
    assert failure["record_kind"] == "task_offer"
  end

  defp successful_before_execute(scenario, fake, cassette) do
    assert {:ok, callback} = WorldHostReplay.before_execute(scenario, fake, cassette: cassette)
    callback
  end

  defp scenario_companions(scenario) do
    Enum.map(WorldCase.repository_requirements(scenario), fn requirement ->
      %{
        "base_commit" => requirement["base_commit"],
        "name" => requirement["name"],
        "path" => "/coop/repositories/#{requirement["name"]}"
      }
    end)
  end

  defp record_state_tool!("request_task", claim) do
    assert {:ok, %{"record_ref" => record_ref}} =
             Tools.call(
               "request_task",
               %{
                 "authority_limits" => ["do not deploy or publish"],
                 "instruction_ref" => "input:trusted:1",
                 "prompt" =>
                   "Add bounded context to Gate timeout logs and aggregate failures in five-minute windows.",
                 "repository" => "rivals-scraper",
                 "source_refs" => [],
                 "success_checks" => ["focused repository tests pass"],
                 "title" => "Bound Gate timeout context"
               },
               binding_options(claim)
             )

    {record_ref, "complete", "Prepared one bounded engineering task for confirmation."}
  end

  defp record_state_tool!("request_input", claim) do
    assert {:ok, %{"record_ref" => record_ref}} =
             Tools.call(
               "request_input",
               %{
                 "context" =>
                   "The steady-state budget is fixed; rollout surge is the open choice.",
                 "questions" => [
                   %{
                     "choices" => ["Allow temporary surge", "Keep exactly two VMs"],
                     "text" => "May the rollout temporarily exceed two VMs?"
                   }
                 ]
               },
               binding_options(claim)
             )

    {record_ref, "waiting_for_input", "I need one rollout-capacity choice before proceeding."}
  end

  defp record_state_tool!("propose_automation", claim) do
    assert {:ok, %{"proposals" => [%{"record_ref" => record_ref}]}} =
             Tools.call(
               "propose_automation",
               %{
                 "proposals" => [
                   %{
                     "action" => "create",
                     "catch_up" => "latest",
                     "patch" => %{},
                     "prompt" =>
                       "Prepare a fresh evidence-backed production health review and report it in this conversation.",
                     "repository" => nil,
                     "title" => "Weekly production health review",
                     "trigger" => %{
                       "recurrence" => "weekly",
                       "time" => "09:00:00",
                       "timezone" => "Etc/UTC",
                       "type" => "time",
                       "weekday" => "monday"
                     }
                   }
                 ]
               },
               binding_options(claim)
             )

    {record_ref, "complete", "Prepared the weekly schedule for confirmation."}
  end

  defp record_state_tool!("wait_for", claim) do
    assert {:ok, %{"record_ref" => record_ref}} =
             Tools.call(
               "wait_for",
               %{
                 "deadline" => "2099-08-27T20:28:13.000000Z",
                 "on_timeout" => "Report that revision 99183465 could not be verified in time.",
                 "trigger" => %{
                   "match" => %{"revision" => "99183465", "state" => "verification_due"},
                   "source_kind" => "terraform",
                   "type" => "source_event"
                 },
                 "verification" =>
                   "Verify Airflow revision 99183465 after the observation window."
               },
               binding_options(claim)
             )

    {record_ref, "waiting_for_event",
     "I will verify revision 99183465 after the observation window."}
  end

  defp record_state_tool!("propose_memory", claim) do
    assert {:ok, %{"record_ref" => record_ref}} =
             Tools.call(
               "propose_memory",
               %{
                 "expires_at" => nil,
                 "kind" => "guidance",
                 "scope" => "current_channel",
                 "source_refs" => ["input:trusted:1"],
                 "subject" => "deployment_completion",
                 "supersedes" => [],
                 "value" =>
                   "Verify the exact deployed allocation before reporting a deployment complete."
               },
               binding_options(claim)
             )

    {record_ref, "complete", "Prepared the deployment-verification guidance for confirmation."}
  end

  defp record_incident_task_tool!(claim) do
    assert {:ok, %{"record_ref" => record_ref}} =
             Tools.call(
               "request_task",
               %{
                 "authority_limits" => ["read-only investigation; do not change production"],
                 "instruction_ref" => "input:operator:incident:1",
                 "kind" => "incident",
                 "prompt" => "Investigate the recurring production portal HTTP 503 reports.",
                 "repository" => nil,
                 "source_refs" => [],
                 "success_checks" => ["current production evidence is reviewed"],
                 "title" => "Recurring production portal 503 reports"
               },
               binding_options(claim)
             )

    {record_ref, "complete", "Prepared one incident investigation for confirmation."}
  end

  defp eval_only_source_tool do
    %{
      "description" => "A source tool unique to this runner invocation.",
      "inputSchema" => %{
        "additionalProperties" => false,
        "properties" => %{},
        "type" => "object"
      },
      "name" => "eval.only"
    }
  end

  defp binding_options(claim) do
    %{
      binding: %{
        episode: claim.episode,
        session: claim.session,
        state_token: Records.token(claim.turn),
        turn: claim.turn
      },
      capabilities: [:event_waits, :publication, :schedules]
    }
  end

  defp work_dispatcher_options(fake, suffix) do
    [
      executor_options: [
        api: FakeWorkCoopAPI,
        client: fake,
        state_tools_endpoint: "https://eval.example/v1/state-tools/mcp",
        state_tools_secret: "world-eval-state-tools-secret"
      ],
      lease_seconds: 300,
      max_attempts: 4,
      retry_base_seconds: 1,
      retry_max_seconds: 1,
      worker_ref: "world-worker:#{suffix}"
    ]
  end

  defp poison_poll_subscription!(record_id, mutation) do
    subscription = Repo.get_by!(EventSubscription, record_id: record_id)

    case mutation do
      :missing ->
        Repo.delete!(subscription)

      :inactive ->
        Repo.update_all(
          from(value in EventSubscription, where: value.id == ^subscription.id),
          set: [status: :cancelled]
        )

      :expired ->
        Repo.update_all(
          from(value in EventSubscription, where: value.id == ^subscription.id),
          set: [deadline_at: subscription.poll_after]
        )

      :not_due ->
        Repo.update_all(
          from(value in EventSubscription, where: value.id == ^subscription.id),
          set: [poll_after: DateTime.add(subscription.poll_after, 1, :second)]
        )

      :stale ->
        Repo.update_all(
          from(value in Responder.State.Record, where: value.id == ^record_id),
          set: [status: :dismissed]
        )
    end

    :ok
  end

  defp final_candidate(state, message, record_refs) do
    Jason.encode!(%{
      "decision_reason" => nil,
      "delivery" => "reply",
      "message" => message,
      "outcome" => %{
        "artifact_refs" => [],
        "record_refs" => record_refs,
        "state" => state
      }
    })
  end
end
