defmodule Responder.Evals.WorldRunnerTest do
  use Responder.DataCase, async: false

  import Ecto.Query

  alias Responder.Artifacts.Outputs
  alias Responder.Delivery.Adapters
  alias Responder.Delivery.Dispatcher, as: DeliveryDispatcher
  alias Responder.Episodes
  alias Responder.Episodes.Command
  alias Responder.Evals.{SlackDeliveryPublisher, WorldCase, WorldCassette, WorldRunner}
  alias Responder.Repo
  alias Responder.Slack.ChannelConfiguration
  alias Responder.State.Records
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
    terraform-run-update-stays-in-one-session
  )

  test "cleanup diagnostics preserve the primary model-world failure" do
    primary = {:error, {:world_eval_failed, :work_retry_exhausted}}
    cleanup = {:error, {:world_cleanup_blocked, :session_cleanup_error}}

    assert {:error,
            {:world_eval_failed_with_cleanup, {:world_eval_failed, :work_retry_exhausted},
             {:world_cleanup_blocked, :session_cleanup_error}}} =
             WorldRunner.finish_result(primary, cleanup)
  end

  test "cleanup diagnostics do not change a successful cleanup result" do
    success = {:ok, %{status: :passed}}

    assert success == WorldRunner.finish_result(success, :ok)
  end

  test "local disposable cleanup still runs when remote cleanup fails" do
    parent = self()

    assert {:error, {:world_cleanup_blocked, :session_cleanup_error}} =
             WorldRunner.run_cleanup(
               fn -> {:error, {:world_cleanup_blocked, :session_cleanup_error}} end,
               fn ->
                 send(parent, :local_cleanup_ran)
                 :ok
               end
             )

    assert_receive :local_cleanup_ran
  end

  test "cleanup preserves both independent failures" do
    assert {:error,
            {:model_world_cleanup_failures, :remote_cleanup_failed, :local_cleanup_failed}} =
             WorldRunner.run_cleanup(
               fn -> {:error, :remote_cleanup_failed} end,
               fn -> {:error, :local_cleanup_failed} end
             )
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
      {:ok, cassette} = WorldCassette.start_link(scenario)
      on_exit(fn -> if Process.alive?(fake), do: Agent.stop(fake) end)
      on_exit(fn -> if Process.alive?(turn_counter), do: Agent.stop(turn_counter) end)
      on_exit(fn -> if Process.alive?(cassette), do: GenServer.stop(cassette) end)

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
          Enum.count(scenario.world["scheduled_events"], &(&1["kind"] == "source_event"))

      assert length(report.deliveries) == input_count
      assert Enum.all?(report.deliveries, &(&1.target.transport == "slack"))
      assert FakeWorkCoopAPI.state(fake).submit_count == input_count
      assert FakeWorkCoopAPI.state(fake).create_count == 1

      if @scenario_id == "terraform-run-update-stays-in-one-session" do
        assert FakeWorkCoopAPI.state(fake).lost_submit_response
        assert FakeWorkCoopAPI.state(fake).submit_count == input_count
      end

      if @scenario_id == "current-uptime-check-uses-fresh-source" do
        assert FakeWorkCoopAPI.state(fake).submit_error_count == 1
        assert FakeWorkCoopAPI.state(fake).submit_count == 1
      end

      turns = Enum.map(report.turn_ids, &Repo.get!(Turn, &1))

      assert Enum.map(turns, &get_in(&1.submission, ["context", "mode"])) ==
               ["full" | List.duplicate("continuation", input_count - 1)]

      assert turns |> Enum.map(& &1.session_id) |> Enum.uniq() |> length() == 1

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
          Enum.count(scenario.world["scheduled_events"], &(&1["kind"] == "source_event"))

      assert report.failures == []
      assert length(report.deliveries) == input_count
      assert Enum.all?(report.deliveries, &(&1.target.transport == "slack"))
      assert FakeWorkCoopAPI.state(fake).submit_count == input_count
      assert FakeWorkCoopAPI.state(fake).create_count == 1

      turns = Enum.map(report.turn_ids, &Repo.get!(Turn, &1))
      assert turns |> Enum.map(& &1.session_id) |> Enum.uniq() |> length() == 1

      if @scenario_id == "artifact-delivery-survives-work-handoff" do
        assert [delivery] = report.deliveries
        assert delivery.attempts == 2

        assert [
                 %{
                   bytes: 28,
                   media_type: "image/png",
                   name: "handoff-chart.png",
                   ref: "artifact_9a576f4bf152aa618b4d8233",
                   sha256: "9a576f4bf152aa618b4d823351908202080af5c99566589f72bd24aad6ca6746"
                 }
               ] = delivery.artifacts

        assert {:ok, [stored]} =
                 Outputs.fetch_many(report.turn_id, ["artifact_9a576f4bf152aa618b4d8233"])

        assert stored.data ==
                 <<137, 80, 78, 71, 13, 10, 26, 10, "world-artifact-chart">>
      end

      if @scenario_id == "noisy-context-keeps-current-request" do
        [turn] = turns
        [current] = get_in(turn.submission, ["context", "inputs", "items"])

        assert current["content"]["text"] =~ "current-request-7f3a"
        assert length(current["content"]["nearby_context"]) == 20

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

      assert @expected_judge_result ==
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
    assert failure["actor_ref"] == "schedule:whole-platform-health-review"
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
