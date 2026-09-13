defmodule Ryker.Admission.DispatcherTest do
  use Ryker.DataCase, async: true

  # A suite-owned workspace keeps conversation locks out of other async fixtures.

  @moduletag isolation: "REPEATABLE READ"

  alias Ryker.Admission
  alias Ryker.Admission.{Decision, Dispatcher, Executor}
  alias Ryker.Admission.DispatcherTest.ExecutorStub
  alias Ryker.Episodes
  alias Ryker.Episodes.Command
  alias Ryker.Ingress.Inbox
  alias Ryker.Slack.Input
  alias Ryker.TestSupport.FakeCoopAPI, as: FakeAPI

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

  test "a poisoned input exhausts its retry budget and releases later messages in its channel" do
    # One permanently failing input previously retried forever and muted every
    # later human request in the same channel, without appearing in Failures.
    first = record_input!("Ev-poisoned-input")

    second =
      record_input!("Ev-after-poisoned-input",
        message_ref: "1787832001.000100",
        occurred_at: DateTime.add(@now, 1, :second)
      )

    {:ok, stub} = ExecutorStub.start_link(:fail)
    first_ref = Inbox.ref(first)

    for attempt <- 1..7 do
      at = DateTime.add(@now, (attempt - 1) * 61, :second)

      assert {:ok, {:deferred, ^first_ref, {:coop_unavailable, :simulated}}} =
               Dispatcher.run_once(Keyword.put(options(stub), :now, fn -> at end))
    end

    at = DateTime.add(@now, 7 * 61, :second)

    assert {:ok, {:blocked, ^first_ref, {:coop_unavailable, :simulated}}} =
             Dispatcher.run_once(Keyword.put(options(stub), :now, fn -> at end))

    assert {:ok, blocked} = Inbox.fetch(first_ref)
    assert blocked.status == :blocked
    assert blocked.attempt_count == 8
    assert blocked.last_error_code == "coop_unavailable"
    assert blocked.lease_ref == nil
    assert blocked.next_attempt_at == nil

    ExecutorStub.succeed(stub)

    assert {:ok, {:decided, execution}} =
             Dispatcher.run_once(Keyword.put(options(stub), :now, fn -> at end))

    assert execution.result.entry.id == second.id

    # Manual retry retains occurrence keys and can reconcile the original input;
    # exhausting automatic retries must not erase it or invent a new generation.
    assert {:ok, rearmed} = Inbox.rearm(first_ref)
    assert rearmed.execution_generation == first.execution_generation
    assert rearmed.validation_generation == first.validation_generation

    assert {:ok, {:decided, retried}} =
             Dispatcher.run_once(Keyword.put(options(stub), :now, fn -> at end))

    assert retried.result.entry.id == first.id
  end

  test "a persistently stale routing context eventually releases its conversation without calling a model" do
    entry = record_input!("Ev-admission-overflow")
    reason = {:admission_rejected, :context_stale}
    {:ok, stub} = ExecutorStub.start_link({:fail, reason})
    input_ref = Inbox.ref(entry)

    for attempt <- 1..8 do
      at = DateTime.add(@now, (attempt - 1) * 61, :second)
      expected = if attempt == 8, do: :blocked, else: :deferred

      assert {:ok, {^expected, ^input_ref, ^reason}} =
               Dispatcher.run_once(Keyword.put(options(stub), :now, fn -> at end))
    end

    assert {:ok, blocked} = Inbox.fetch(input_ref)
    assert blocked.status == :blocked
    assert blocked.attempt_count == 8
  end

  for {wrapper, field} <- [
        {:admission_generation_spent, :execution_generation},
        {:admission_validation_generation_spent, :validation_generation}
      ] do
    test "exhausted #{field} retries keep the next safe occurrence for operator recovery" do
      # A terminal occurrence cannot be reused. Merely blocking at the budget
      # would trap every operator retry on that same already-finished occurrence.
      entry = record_input!("Ev-exhausted-#{unquote(field)}")
      input_ref = Inbox.ref(entry)
      reason = {:coop_unavailable, :confirmed_terminal_failure}
      {:ok, stub} = ExecutorStub.start_link({:fail, {unquote(wrapper), reason}})

      for attempt <- 1..8 do
        at = DateTime.add(@now, (attempt - 1) * 61, :second)
        expected = if attempt == 8, do: :blocked, else: :deferred

        assert {:ok, {^expected, ^input_ref, ^reason}} =
                 Dispatcher.run_once(Keyword.put(options(stub), :now, fn -> at end))
      end

      assert {:ok, blocked} = Inbox.fetch(input_ref)
      assert Map.fetch!(blocked, unquote(field)) == 9
      assert {:ok, rearmed} = Inbox.rearm(input_ref)
      assert Map.fetch!(rearmed, unquote(field)) == 9
    end
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

  test "a placement lost before the session existed is replaced on the next attempt" do
    # A worker that stops polling lets the admission placement expire before its
    # create_session command ever leaves the host. The fleet then answers every
    # command for that session with coop_session_replacement_required, which Work
    # rotates past but admission retried verbatim: on 2026-09-13 one Slack input
    # burned all eight attempts against the same dead session and blocked, and
    # only an operator rearm, which happens to move the generation, freed it.
    entry = record_input!("Ev-dispatch-placement-lost")

    {:ok, fake} =
      FakeAPI.start_link([decision()],
        first_create_error: {:coop_session_replacement_required, Ecto.UUID.generate(), 1}
      )

    assert {:ok, {:deferred, input_ref, {:coop_session_replacement_required, _session, 1}}} =
             Dispatcher.run_once(real_options(fake, @now))

    assert input_ref == Inbox.ref(entry)
    assert {:ok, deferred} = Inbox.fetch(input_ref)
    assert Map.fetch!(deferred, :execution_generation) == 2

    assert {:ok, {:decided, execution}} =
             Dispatcher.run_once(real_options(fake, DateTime.add(@now, 2, :second)))

    assert execution.result.entry.status == :decided
    assert execution.result.entry.execution_generation == 2
    assert [first, second] = FakeAPI.state(fake).create_keys
    assert first =~ ":g1"
    assert second =~ ":g2"
  end

  test "a terminal worker failure waits for operator recovery instead of launching another model" do
    entry = record_input!("Ev-dispatch-terminal-turn")
    {:ok, fake} = FakeAPI.start_link([decision()], fail_first_turn: true)

    assert {:ok, {:blocked, input_ref, {:coop_turn_failed, "failed", _, _}}} =
             Dispatcher.run_once(real_options(fake, @now))

    assert input_ref == Inbox.ref(entry)
    assert {:ok, deferred} = Inbox.fetch(input_ref)
    assert Map.fetch!(deferred, :execution_generation) == 2

    assert {:ok, :idle} =
             Dispatcher.run_once(real_options(fake, DateTime.add(@now, 2, :second)))

    assert FakeAPI.state(fake).submit_count == 1
    assert {:ok, _rearmed} = Inbox.rearm(input_ref)

    assert {:ok, {:decided, execution}} =
             Dispatcher.run_once(real_options(fake, DateTime.add(@now, 2, :second)))

    assert execution.result.entry.status == :decided
    state = FakeAPI.state(fake)
    assert state.submit_count == 2
    assert state.failed_turn_key =~ ":g1:"
    assert Enum.any?(state.turn_keys, &String.contains?(&1, ":g2:"))
  end

  test "recorded worker startup and quota failures block once with their actual diagnosis" do
    # Input b8bff9f3 on 2026-09-09 spent fifteen admission executions on an
    # incompatible worker and an exhausted account. Coop already owns failover;
    # resubmitting its terminal failure only repeats the same frozen request.
    for {code, detail} <- [
          {"acp_process_error", "ACP child closed before its response"},
          {"acp_protocol_error",
           "provider limit prevented the turn: You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits or try again at Sep 15th, 2026 4:32 PM."}
        ] do
      entry = record_input!("Ev-recorded-#{code}")
      reason = {:coop_turn_failed, "failed", code, detail}
      {:ok, stub} = ExecutorStub.start_link({:fail, {:admission_generation_spent, reason}})

      assert {:ok, {:blocked, input_ref, ^reason}} = Dispatcher.run_once(options(stub))
      assert input_ref == Inbox.ref(entry)
      assert {:ok, blocked} = Inbox.fetch(input_ref)
      assert blocked.attempt_count == 1
      assert blocked.execution_generation == 2
      assert blocked.last_error_code == code
      assert blocked.last_error_detail =~ detail
      assert {:ok, :idle} = Dispatcher.run_once(options(stub))
    end
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
        "repository_source" => nil,
        "reason" => "This looks like a new request related to earlier work.",
        "work_class" => "standard"
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
                 conversation_ref: "slack:TADMISSIONDISPATCH:C456",
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

    addressing_options = [slack_audience: :ambient, slack_bot_user_ref: "UBOT"]
    entry = record_input!("Ev-lost-turn-frozen-context", [], addressing_options)

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
        "repository_source" => nil,
        "reason" => "This is new work with useful history.",
        "work_class" => "standard"
      })

    continue_reopened =
      Jason.encode!(%{
        "action" => "continue_episode",
        "episode_ref" => candidate.ref,
        "reaction" => nil,
        "relation" => "same_work",
        "repository_source" => nil,
        "reason" => "This belongs to the reopened work.",
        "work_class" => "standard"
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
    addressing = %{"audience" => "ambient", "ryker_user_ref" => "UBOT"}
    assert frozen.admission_context["slack_addressing"] == addressing
    submitted_prompt = FakeAPI.state(fake).submitted_prompt
    assert Jason.decode!(submitted_prompt)["context"]["slack_addressing"] == addressing

    # A later host configuration change cannot rewrite the first receipt or its frozen request.
    retried_entry =
      record_input!("Ev-lost-turn-frozen-context", [],
        slack_audience: :mention,
        slack_bot_user_ref: "UNEWBOT"
      )

    assert retried_entry.slack_audience == :ambient
    assert retried_entry.slack_bot_user_ref == "UBOT"

    assert {:ok, reopened} =
             Episodes.apply(%Command.AdmitInput{
               actor_ref: "slack:user:U-reopen",
               destination: %{
                 conversation_ref: "slack:TADMISSIONDISPATCH:C456",
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
    assert FakeAPI.state(fake).submitted_prompt == submitted_prompt

    assert {:ok, {:decided, execution}} =
             Dispatcher.run_once(real_options(fake, DateTime.add(@now, 4, :second)))

    assert execution.result.episode.id == episode_id
    assert FakeAPI.state(fake).submit_count == 2

    assert Jason.decode!(FakeAPI.state(fake).submitted_prompt)["context"]["slack_addressing"] ==
             addressing
  end

  test "a conversation full of active work no longer stalls; the shortlist is simply bounded" do
    # Admission used to refuse to run at all when more active episodes existed
    # than the option limit, so one busy thread could hold up every later
    # message in its conversation until capacity happened to free up.
    entry = record_input!("Ev-candidate-overflow", actor: %{kind: :app, ref: "A-history"})

    for index <- 1..9 do
      assert {:ok, _transition} =
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
    end

    {:ok, fake} = FakeAPI.start_link([decision()])

    options =
      real_options(fake, @now)
      |> Keyword.update!(:executor_options, &Keyword.put(&1, :candidate_limit, 8))

    assert {:ok, {:decided, execution}} = Dispatcher.run_once(options)
    assert execution.result.entry.status == :decided
    assert FakeAPI.state(fake).submit_count == 1

    offered = Jason.decode!(FakeAPI.state(fake).submitted_prompt)["context"]["candidates"]
    assert length(offered) <= 8
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

  defp record_input!(event_ref, overrides \\ [], record_options \\ []) do
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
               workspace_ref: "TADMISSIONDISPATCH"
             ]
             |> Keyword.merge(overrides)
             |> Input.new()

    assert {:ok, %{entry: entry}} = Inbox.record(input, record_options)
    entry
  end

  defp decision(action \\ "reply") do
    Jason.encode!(%{
      "action" => action,
      "episode_ref" => nil,
      "reaction" => nil,
      "relation" => "unrelated",
      "repository_source" => nil,
      "reason" => "The incoming request can receive an immediate answer.",
      "work_class" => if(action == "reply", do: "conversational", else: "standard")
    })
  end

  defmodule ExecutorStub do
    alias Ryker.Admission
    alias Ryker.Admission.Decision

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
        "repository_source" => nil,
        "reason" => "The incoming request can receive an immediate answer.",
        "work_class" => "conversational"
      })
    end
  end
end
