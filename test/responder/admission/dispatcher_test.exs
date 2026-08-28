defmodule Responder.Admission.DispatcherTest do
  use Responder.DataCase, async: true

  @moduletag isolation: "REPEATABLE READ"

  alias Responder.Admission
  alias Responder.Admission.{Decision, Dispatcher, Executor}
  alias Responder.Admission.DispatcherTest.ExecutorStub
  alias Responder.Episodes
  alias Responder.Episodes.Command
  alias Responder.Ingress.Inbox
  alias Responder.Slack.Input
  alias Responder.TestSupport.FakeCoopAPI, as: FakeAPI

  @now ~U[2026-08-27 12:00:00.000000Z]

  test "claims and decides one durable input" do
    entry = record_input!("Ev-dispatch-success")
    {:ok, stub} = ExecutorStub.start_link(:succeed)

    assert {:ok, {:decided, execution}} = Dispatcher.run_once(options(stub))
    assert execution.result.entry.id == entry.id
    assert execution.result.entry.status == :decided
    assert execution.result.entry.lease_ref == nil
    assert {:ok, :idle} = Dispatcher.run_once(options(stub))
  end

  test "a transient failure is durably deferred and retried without losing the input" do
    entry = record_input!("Ev-dispatch-retry")
    {:ok, stub} = ExecutorStub.start_link(:fail)

    assert {:ok, {:deferred, input_ref, {:coop_unavailable, :simulated}}} =
             Dispatcher.run_once(options(stub))

    assert input_ref == Inbox.ref(entry)
    assert {:ok, deferred} = Inbox.fetch(input_ref)
    assert deferred.status == :pending
    assert deferred.attempt_count == 1
    assert deferred.lease_ref == nil
    assert deferred.last_error_code == "coop_unavailable"
    assert DateTime.compare(deferred.next_attempt_at, DateTime.add(@now, 1, :second)) == :eq

    assert {:ok, :idle} = Dispatcher.run_once(options(stub))

    ExecutorStub.succeed(stub)
    later_options = Keyword.put(options(stub), :now, fn -> DateTime.add(@now, 2, :second) end)

    assert {:ok, {:decided, execution}} = Dispatcher.run_once(later_options)
    assert execution.result.entry.id == entry.id
    assert execution.result.entry.attempt_count == 2
  end

  test "a maximum-size multibyte Coop error is durably deferred with its lease released" do
    entry = record_input!("Ev-dispatch-large-multibyte-error")

    reason =
      {:coop_error, 503, "provider_error", String.duplicate("😀", 1_024)}

    {:ok, stub} = ExecutorStub.start_link({:fail, reason})

    assert {:ok, {:deferred, input_ref, ^reason}} = Dispatcher.run_once(options(stub))
    assert input_ref == Inbox.ref(entry)
    assert {:ok, deferred} = Inbox.fetch(input_ref)
    assert deferred.status == :pending
    assert deferred.lease_ref == nil
    assert byte_size(deferred.last_error_detail) <= 4_096
    assert String.valid?(deferred.last_error_detail)
  end

  test "retry delay starts when execution fails rather than when its lease was claimed" do
    entry = record_input!("Ev-dispatch-slow-failure")
    {:ok, stub} = ExecutorStub.start_link(:fail)

    failure_time = DateTime.add(@now, 30, :second)
    {:ok, clock} = Agent.start_link(fn -> [@now, failure_time] end)

    now = fn ->
      Agent.get_and_update(clock, fn [current | rest] -> {current, rest} end)
    end

    assert {:ok, {:deferred, input_ref, {:coop_unavailable, :simulated}}} =
             Dispatcher.run_once(Keyword.put(options(stub), :now, now))

    assert input_ref == Inbox.ref(entry)
    assert {:ok, deferred} = Inbox.fetch(input_ref)

    assert DateTime.compare(
             deferred.next_attempt_at,
             DateTime.add(failure_time, 1, :second)
           ) == :eq
  end

  test "a confirmed failed Coop operation advances once and then completes with fresh keys" do
    entry = record_input!("Ev-dispatch-terminal-operation")
    {:ok, fake} = FakeAPI.start_link([decision()], fail_first_operation: true)

    assert {:ok, {:deferred, input_ref, {:coop_operation_failed, _, _}}} =
             Dispatcher.run_once(real_options(fake, @now))

    assert input_ref == Inbox.ref(entry)
    assert {:ok, deferred} = Inbox.fetch(input_ref)
    assert Map.fetch!(deferred, :execution_generation) == 2

    assert {:ok, {:decided, execution}} =
             Dispatcher.run_once(real_options(fake, DateTime.add(@now, 2, :second)))

    assert execution.result.entry.status == :decided
    assert execution.result.entry.execution_generation == 2
    state = FakeAPI.state(fake)
    assert state.submit_count == 1
    assert state.failed_operation_key =~ ":g1"
    assert Enum.any?(Map.keys(state.operation_calls), &String.contains?(&1, ":g2"))
  end

  test "a confirmed terminal Coop turn advances once and is reclassified" do
    entry = record_input!("Ev-dispatch-terminal-turn")
    {:ok, fake} = FakeAPI.start_link([decision()], fail_first_turn: true)

    assert {:ok, {:deferred, input_ref, {:coop_turn_failed, "failed", _, _}}} =
             Dispatcher.run_once(real_options(fake, @now))

    assert input_ref == Inbox.ref(entry)
    assert {:ok, deferred} = Inbox.fetch(input_ref)
    assert Map.fetch!(deferred, :execution_generation) == 2

    assert {:ok, {:decided, execution}} =
             Dispatcher.run_once(real_options(fake, DateTime.add(@now, 2, :second)))

    assert execution.result.entry.status == :decided
    state = FakeAPI.state(fake)
    assert state.submit_count == 2
    assert state.failed_turn_key =~ ":g1:"
    assert Enum.any?(state.turn_keys, &String.contains?(&1, ":g2:"))
  end

  test "operator and policy terminal turns stop without silently starting a new session" do
    for state <- ~w(cancelled interrupted budget_exhausted) do
      entry = record_input!("Ev-terminal-#{state}")

      {:ok, fake} =
        FakeAPI.start_link([decision()], fail_first_turn: true, first_turn_state: state)

      assert {:ok, {:blocked, input_ref, {:coop_turn_stopped, ^state, _, _}}} =
               Dispatcher.run_once(real_options(fake, @now))

      assert input_ref == Inbox.ref(entry)
      assert {:ok, blocked} = Inbox.fetch(input_ref)
      assert blocked.status == :blocked
      assert blocked.execution_generation == 1
      assert blocked.lease_ref == nil

      assert {:ok, :idle} =
               Dispatcher.run_once(real_options(fake, DateTime.add(@now, 2, :second)))

      state_record = FakeAPI.state(fake)
      assert state_record.submit_count == 1
      refute Enum.any?(state_record.turn_keys, &String.contains?(&1, ":g2:"))
    end
  end

  test "a confirmed failed semantic validation retries with a fresh generation" do
    entry = record_input!("Ev-dispatch-terminal-validation")

    {:ok, fake} =
      FakeAPI.start_link([decision()], fail_first_validation: true)

    assert {:ok, {:deferred, input_ref, {:coop_error, 503, "session_cleanup_error", _}}} =
             Dispatcher.run_once(real_options(fake, @now))

    assert input_ref == Inbox.ref(entry)
    assert {:ok, deferred} = Inbox.fetch(input_ref)
    assert Map.fetch!(deferred, :execution_generation) == 1
    assert Map.fetch!(deferred, :validation_generation) == 2

    assert {:ok, {:decided, execution}} =
             Dispatcher.run_once(real_options(fake, DateTime.add(@now, 2, :second)))

    assert execution.result.entry.status == :decided
    assert execution.result.entry.execution_generation == 1
    state = FakeAPI.state(fake)
    assert state.submit_count == 1
    assert Enum.map(state.validations, & &1.verdict) == [:accept]
    assert Enum.map(state.validation_keys, &Regex.run(~r/:v\d+:/, &1)) == [[":v1:"], [":v2:"]]
  end

  test "an ambiguous transport failure retains the same Coop operation generation" do
    entry = record_input!("Ev-dispatch-ambiguous-transport")
    {:ok, fake} = FakeAPI.start_link([decision()], fail_create: true)

    assert {:ok, {:deferred, input_ref, {:coop_unavailable, :simulated}}} =
             Dispatcher.run_once(real_options(fake, @now))

    assert input_ref == Inbox.ref(entry)
    assert {:ok, deferred} = Inbox.fetch(input_ref)
    assert Map.fetch!(deferred, :execution_generation) == 1

    FakeAPI.allow_create(fake)

    assert {:ok, {:decided, execution}} =
             Dispatcher.run_once(real_options(fake, DateTime.add(@now, 2, :second)))

    assert execution.result.entry.status == :decided
    assert Enum.uniq(FakeAPI.state(fake).create_keys) |> length() == 1
    assert hd(FakeAPI.state(fake).create_keys) =~ ":g1"
  end

  test "an uncertain validation enters durable reconciliation custody without replay" do
    entry = record_input!("Ev-dispatch-uncertain-validation")

    {:ok, fake} =
      FakeAPI.start_link([decision()],
        fail_first_validation: true,
        first_validation_error:
          {:coop_error, 409, "operation_uncertain", "validation outcome is unknown"}
      )

    assert {:ok, {:blocked, input_ref, {:coop_error, 409, "operation_uncertain", _}}} =
             Dispatcher.run_once(real_options(fake, @now))

    assert input_ref == Inbox.ref(entry)
    assert {:ok, blocked} = Inbox.fetch(input_ref)
    assert blocked.status == :blocked
    assert blocked.execution_generation == 1
    assert blocked.validation_generation == 1
    assert blocked.lease_ref == nil
    assert blocked.next_attempt_at == nil

    assert {:ok, :idle} =
             Dispatcher.run_once(real_options(fake, DateTime.add(@now, 2, :second)))

    state = FakeAPI.state(fake)
    assert state.submit_count == 1
    assert Enum.uniq(state.validation_keys) |> length() == 1
    assert hd(state.validation_keys) =~ ":g1:a1:v1:"
  end

  test "a maximum-size escaped Coop error enters durable blocked custody" do
    entry = record_input!("Ev-dispatch-large-escaped-error")
    detail = String.duplicate("\n", 4_096)

    {:ok, fake} =
      FakeAPI.start_link([decision()],
        fail_first_validation: true,
        first_validation_error: {:coop_error, 409, "operation_uncertain", detail}
      )

    assert {:ok, {:blocked, input_ref, {:coop_error, 409, "operation_uncertain", ^detail}}} =
             Dispatcher.run_once(real_options(fake, @now))

    assert input_ref == Inbox.ref(entry)
    assert {:ok, blocked} = Inbox.fetch(input_ref)
    assert blocked.status == :blocked
    assert blocked.lease_ref == nil
    assert byte_size(blocked.last_error_detail) <= 4_096
    assert String.valid?(blocked.last_error_detail)
  end

  test "a mismatched semantic validation receipt is blocked and cannot commit on retry" do
    entry = record_input!("Ev-dispatch-validation-mismatch")

    {:ok, fake} =
      FakeAPI.start_link([decision("reply")],
        accepted_candidate_override: decision("start_episode")
      )

    assert {:ok, {:blocked, input_ref, {:coop_protocol_error, :validated_candidate_mismatch}}} =
             Dispatcher.run_once(real_options(fake, @now))

    assert input_ref == Inbox.ref(entry)
    assert {:ok, blocked} = Inbox.fetch(input_ref)
    assert blocked.status == :blocked
    assert blocked.decision_ref == nil
    assert FakeAPI.state(fake).submit_count == 1
    assert FakeAPI.state(fake).closed

    assert {:ok, :idle} =
             Dispatcher.run_once(real_options(fake, DateTime.add(@now, 2, :second)))
  end

  test "a mismatched receipt remains blocked when its session close response is lost" do
    entry = record_input!("Ev-dispatch-validation-mismatch-close-loss")

    {:ok, fake} =
      FakeAPI.start_link([decision("reply")],
        accepted_candidate_override: decision("start_episode"),
        fail_first_close: true
      )

    assert {:ok, {:blocked, input_ref, reason}} =
             Dispatcher.run_once(real_options(fake, @now))

    assert input_ref == Inbox.ref(entry)
    assert reason |> inspect() =~ "validated_candidate_mismatch"
    assert reason |> inspect() =~ "simulated_close_response_loss"
    assert {:ok, blocked} = Inbox.fetch(input_ref)
    assert blocked.status == :blocked
    assert blocked.decision_ref == nil
    assert FakeAPI.state(fake).submit_count == 1

    assert {:ok, :idle} =
             Dispatcher.run_once(real_options(fake, DateTime.add(@now, 2, :second)))
  end

  test "an input made stale by a newer revision is terminally superseded after one model turn" do
    entry = record_input!("Ev-stale-revision")
    episode_key = "stale-revision:#{entry.id}"

    assert {:ok, _transition} =
             Episodes.apply(%Command.AdmitInput{
               actor_ref: "slack:app:A-newer",
               destination: %{
                 conversation_ref: entry.destination_conversation_ref,
                 thread_ref: entry.destination_thread_ref,
                 transport: entry.destination_transport
               },
               episode_id: Ecto.UUID.generate(),
               episode_key: episode_key,
               linked_episode_id: nil,
               native_input_id: entry.native_input_id,
               occurred_at: DateTime.add(@now, 1, :second),
               payload: %{"text" => "newer edit already admitted"},
               revision: 2,
               turn_ref: "turn-newer-revision"
             })

    assert {:ok, context} =
             Admission.context(Inbox.ref(entry),
               candidate_limit: 8,
               continuation_window: 1_800,
               history_window: 86_400,
               now: DateTime.add(@now, 2, :second)
             )

    candidate = Enum.find(context.candidates, &(&1.episode.key == episode_key))
    assert candidate

    stale_start =
      Jason.encode!(%{
        "action" => "start_episode",
        "episode_ref" => candidate.ref,
        "reaction" => nil,
        "relation" => "history_only",
        "reason" => "This looks like a new request related to earlier work."
      })

    {:ok, fake} = FakeAPI.start_link([stale_start])

    assert {:ok, {:decided, execution}} =
             Dispatcher.run_once(real_options(fake, DateTime.add(@now, 2, :second)))

    assert execution.result.status == :superseded
    assert execution.result.entry.status == :superseded
    assert execution.result.entry.decision_action == :start_episode
    assert execution.result.entry.last_error_code == "stale_input_revision"
    assert FakeAPI.state(fake).submit_count == 1
    assert Enum.map(FakeAPI.state(fake).validations, & &1.verdict) == [:accept]
    assert Enum.all?(FakeAPI.state(fake).turn_keys, &String.contains?(&1, ":g1:"))

    assert {:ok, :idle} =
             Dispatcher.run_once(real_options(fake, DateTime.add(@now, 4, :second)))
  end

  test "a lost close response leaves the input pending and reconciles without another model turn" do
    entry = record_input!("Ev-close-response-loss")
    {:ok, fake} = FakeAPI.start_link([decision()], fail_first_close: true)

    assert {:ok, {:deferred, input_ref, {:coop_unavailable, :simulated_close_response_loss}}} =
             Dispatcher.run_once(real_options(fake, @now))

    assert input_ref == Inbox.ref(entry)
    assert {:ok, pending} = Inbox.fetch(input_ref)
    assert pending.status == :pending
    assert FakeAPI.state(fake).closed

    assert {:ok, {:decided, execution}} =
             Dispatcher.run_once(real_options(fake, DateTime.add(@now, 2, :second)))

    assert execution.result.entry.status == :decided
    state = FakeAPI.state(fake)
    assert state.submit_count == 1
    assert Enum.uniq(state.close_keys) |> length() == 1
  end

  test "a healthy long turn renews its lease before another worker can reclaim it" do
    entry = record_input!("Ev-long-turn-lease")
    {:ok, fake} = FakeAPI.start_link([decision()], turn_wait_polls: 3)
    {:ok, clock} = Agent.start_link(fn -> @now end)
    {:ok, competing_claims} = Agent.start_link(fn -> [] end)

    now = fn -> Agent.get(clock, & &1) end

    sleep = fn _milliseconds ->
      later =
        Agent.get_and_update(clock, fn current ->
          next = DateTime.add(current, 1, :second)
          {next, next}
        end)

      claim = Inbox.claim_next("dispatcher:competing", later, 2)
      Agent.update(competing_claims, &(&1 ++ [claim]))
    end

    options =
      fake
      |> real_options(@now)
      |> Keyword.put(:lease_seconds, 2)
      |> Keyword.put(:now, now)
      |> Keyword.update!(:executor_options, fn executor_options ->
        executor_options
        |> Keyword.put(:now, now)
        |> Keyword.put(:poll_interval_ms, 1_000)
        |> Keyword.put(:sleep, sleep)
      end)

    assert {:ok, {:decided, execution}} = Dispatcher.run_once(options)
    assert execution.result.entry.id == entry.id
    assert execution.result.entry.attempt_count == 1
    assert Enum.all?(Agent.get(competing_claims, & &1), &match?({:ok, nil}, &1))
  end

  test "a lost turn response keeps its frozen routing context until reconciliation" do
    thread_ref = "1787832000.000100"
    episode_id = Ecto.UUID.generate()
    episode_key = "frozen-admission-context:#{episode_id}"
    original_time = DateTime.add(@now, -3_600, :second)

    assert {:ok, admitted} =
             Episodes.apply(%Command.AdmitInput{
               actor_ref: "slack:app:A-original",
               destination: %{
                 conversation_ref: "slack:T123:C456",
                 thread_ref: thread_ref,
                 transport: "slack"
               },
               episode_id: episode_id,
               episode_key: episode_key,
               linked_episode_id: nil,
               native_input_id: "slack-message:original-frozen-context",
               occurred_at: original_time,
               payload: %{"text" => "Earlier completed work"},
               revision: 1,
               turn_ref: "turn-original-frozen-context"
             })

    assert {:ok, _completed} =
             Episodes.apply(%Command.AcceptResult{
               decision_reason: "The earlier request completed.",
               delivery: :none,
               delivery_ref: nil,
               episode_key: episode_key,
               expected_turn_ref: admitted.episode.owner_ref,
               next_turn_ref: nil,
               occurred_at: DateTime.add(original_time, 1, :second),
               result_ref: "result-original-frozen-context"
             })

    entry = record_input!("Ev-lost-turn-frozen-context")

    assert {:ok, initial_context} =
             Admission.context(Inbox.ref(entry),
               candidate_limit: 8,
               continuation_window: 1_800,
               history_window: 86_400,
               now: @now
             )

    candidate = Enum.find(initial_context.candidates, &(&1.episode.id == episode_id))
    assert candidate

    start_from_history =
      Jason.encode!(%{
        "action" => "start_episode",
        "episode_ref" => candidate.ref,
        "reaction" => nil,
        "relation" => "history_only",
        "reason" => "This is new work with useful history."
      })

    continue_reopened =
      Jason.encode!(%{
        "action" => "continue_episode",
        "episode_ref" => candidate.ref,
        "reaction" => nil,
        "relation" => "same_work",
        "reason" => "This belongs to the reopened work."
      })

    {:ok, fake} =
      FakeAPI.start_link([start_from_history, continue_reopened],
        fail_first_turn_response: true
      )

    assert {:ok, {:deferred, input_ref, {:coop_unavailable, :simulated_turn_response_loss}}} =
             Dispatcher.run_once(real_options(fake, @now))

    assert {:ok, frozen} = Inbox.fetch(input_ref)
    assert frozen.admission_context_fingerprint
    assert frozen.execution_generation == 1

    assert {:ok, reopened} =
             Episodes.apply(%Command.AdmitInput{
               actor_ref: "slack:user:U-reopen",
               destination: %{
                 conversation_ref: "slack:T123:C456",
                 thread_ref: thread_ref,
                 transport: "slack"
               },
               episode_id: episode_id,
               episode_key: episode_key,
               linked_episode_id: nil,
               native_input_id: "slack-message:reopen-frozen-context",
               occurred_at: DateTime.add(@now, 1, :second),
               payload: %{"text" => "Reopen while the turn response is lost"},
               revision: 1,
               turn_ref: "turn-reopen-frozen-context"
             })

    assert reopened.episode.state == :working

    assert {:ok, {:deferred, ^input_ref, {:admission_rejected, :context_stale}}} =
             Dispatcher.run_once(real_options(fake, DateTime.add(@now, 2, :second)))

    assert :error = Episodes.fetch_by_key("ingress-input:#{entry.id}")
    assert {:ok, reclassified} = Inbox.fetch(input_ref)
    assert reclassified.execution_generation == 2
    assert reclassified.admission_context == nil
    assert FakeAPI.state(fake).submit_count == 1

    assert {:ok, {:decided, execution}} =
             Dispatcher.run_once(real_options(fake, DateTime.add(@now, 4, :second)))

    assert execution.result.episode.id == episode_id
    assert FakeAPI.state(fake).submit_count == 2
  end

  test "candidate overflow waits without a model turn and recovers when capacity returns" do
    entry = record_input!("Ev-candidate-overflow")

    active_episodes =
      for index <- 1..9 do
        assert {:ok, transition} =
                 Episodes.apply(%Command.AdmitInput{
                   actor_ref: "slack:app:A-history",
                   destination: %{
                     conversation_ref: entry.destination_conversation_ref,
                     thread_ref:
                       "1787831000.#{String.pad_leading(Integer.to_string(index), 6, "0")}",
                     transport: entry.destination_transport
                   },
                   episode_id: Ecto.UUID.generate(),
                   episode_key: "candidate-overflow:#{index}:#{entry.id}",
                   linked_episode_id: nil,
                   native_input_id: "slack-message:overflow-#{index}",
                   occurred_at: DateTime.add(@now, -index, :second),
                   payload: %{"text" => "Active work #{index}"},
                   revision: 1,
                   turn_ref: "turn-overflow-#{index}"
                 })

        transition.episode
      end

    {:ok, fake} = FakeAPI.start_link([decision()])

    options =
      real_options(fake, @now)
      |> Keyword.update!(:executor_options, &Keyword.put(&1, :candidate_limit, 8))

    assert {:ok, {:deferred, input_ref, {:admission_context_overflow, required: 9, limit: 8}}} =
             Dispatcher.run_once(options)

    assert input_ref == Inbox.ref(entry)
    assert {:ok, pending} = Inbox.fetch(input_ref)
    assert pending.status == :pending
    assert pending.execution_generation == 1
    assert pending.lease_ref == nil
    assert FakeAPI.state(fake).submit_count == 0
    assert FakeAPI.state(fake).create_keys == []

    [completed | _rest] = active_episodes

    assert {:ok, _transition} =
             Episodes.apply(%Command.AcceptResult{
               decision_reason: "Capacity fixture completed.",
               delivery: :none,
               delivery_ref: nil,
               episode_key: completed.key,
               expected_turn_ref: completed.owner_ref,
               next_turn_ref: nil,
               occurred_at: DateTime.add(@now, 1, :second),
               result_ref: "result-capacity-#{completed.id}"
             })

    later = DateTime.add(@now, 2, :second)

    later_options =
      real_options(fake, later)
      |> Keyword.update!(:executor_options, &Keyword.put(&1, :candidate_limit, 8))

    assert {:ok, {:decided, execution}} = Dispatcher.run_once(later_options)
    assert execution.result.entry.status == :decided
    assert FakeAPI.state(fake).submit_count == 1
  end

  defp options(stub) do
    [
      executor: ExecutorStub,
      executor_options: [stub: stub, now: @now],
      lease_seconds: 300,
      now: fn -> @now end,
      retry_base_ms: 1_000,
      retry_max_ms: 60_000,
      worker_ref: "dispatcher:test"
    ]
  end

  defp real_options(fake, now) do
    [
      executor: Executor,
      executor_options: [
        api: FakeAPI,
        client: fake,
        max_polls: 10,
        now: fn -> now end,
        policy: "admission-read-only",
        policy_digest: String.duplicate("a", 64),
        poll_interval_ms: 0,
        sleep: fn _milliseconds -> :ok end
      ],
      lease_seconds: 300,
      now: fn -> now end,
      retry_base_ms: 1_000,
      retry_max_ms: 60_000,
      worker_ref: "dispatcher:real"
    ]
  end

  defp record_input!(event_ref, overrides \\ []) do
    assert {:ok, input} =
             [
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Please answer this event"},
               event_kind: :message,
               event_ref: event_ref,
               message_ref: "1787832000.000100",
               occurred_at: @now,
               revision: 1,
               thread_ref: nil,
               workspace_ref: "T123"
             ]
             |> Keyword.merge(overrides)
             |> Input.new()

    assert {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  defp decision(action \\ "reply") do
    Jason.encode!(%{
      "action" => action,
      "episode_ref" => nil,
      "reaction" => nil,
      "relation" => "unrelated",
      "reason" => "The incoming request can receive an immediate answer."
    })
  end

  defmodule ExecutorStub do
    alias Responder.Admission
    alias Responder.Admission.Decision

    def start_link(mode), do: Agent.start_link(fn -> mode end)
    def succeed(agent), do: Agent.update(agent, fn _mode -> :succeed end)

    def run(input_ref, options) do
      case Agent.get(Keyword.fetch!(options, :stub), & &1) do
        :fail -> {:error, {:coop_unavailable, :simulated}}
        {:fail, reason} -> {:error, reason}
        _mode -> decide(input_ref, options)
      end
    end

    defp decide(input_ref, options) do
      lease_ref = Keyword.fetch!(options, :lease_ref)

      with {:ok, context} <-
             Admission.context(input_ref,
               candidate_limit: 8,
               continuation_window: 1_800,
               history_window: 86_400,
               lease_ref: lease_ref,
               now: Keyword.fetch!(options, :now)
             ),
           {:ok, decision} <- decision(),
           {:ok, result} <-
             Admission.commit(context, decision, "stub-decision:#{context.input_entry.id}",
               lease_ref: lease_ref
             ) do
        {:ok, %{result: result}}
      end
    end

    defp decision do
      Decision.parse(%{
        "action" => "reply",
        "episode_ref" => nil,
        "reaction" => nil,
        "relation" => "unrelated",
        "reason" => "The incoming request can receive an immediate answer."
      })
    end
  end
end
