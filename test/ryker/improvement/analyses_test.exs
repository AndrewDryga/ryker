defmodule Ryker.Improvement.AnalysesTest do
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.Accounting.Execution
  alias Ryker.Episodes
  alias Ryker.Feedback
  alias Ryker.Fixtures.Answers
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Improvement
  alias Ryker.Improvement.{AnalysisRun, Analyses, Candidate, Dispatcher, Prompt}
  alias Ryker.Retention.Custody, as: RetentionCustody
  alias Ryker.TestSupport.FakeCoopAPI
  alias Ryker.Work.{Custody, Session}

  @workspace "TIMPROVEANALYSES"
  @now ~U[2026-09-27 12:00:00.000000Z]

  # The fleet answers every Coop mutation with an operation still running
  # and the worker finishes it a moment later (the fake's asynchronous mode);
  # a fake that answered at once would prove nothing about waiting.
  defmodule API do
    alias Ryker.TestSupport.FakeCoopAPI, as: Fake

    defdelegate prepare_create_session(client, key, policy, ref, source), to: Fake
    defdelegate create_session(client, key, policy, ref, source), to: Fake
    defdelegate get_session(client, id), to: Fake
    defdelegate get_turn(client, session_id, turn_id), to: Fake
    defdelegate cancel_turn(client, session_id, turn_id, key, revision), to: Fake

    def operation_by_key(client, key) do
      Agent.update(client, &Map.update(&1, :lookups, [key], fn keys -> keys ++ [key] end))
      Fake.operation_by_key(client, key)
    end

    def submit_frozen_turn(client, session_id, key, revision, submission, nil, []) do
      Agent.update(
        client,
        &Map.update(&1, :submissions, [submission], fn all -> all ++ [submission] end)
      )

      Fake.submit_turn(
        client,
        session_id,
        key,
        revision,
        submission["prompt"],
        submission["output_schema"]
      )
    end

    def validate_frozen_candidate(client, session_id, turn_id, key, _attempt, sha256, verdict),
      do: Fake.validate_candidate(client, session_id, turn_id, key, sha256, verdict)
  end

  @diagnosis %{
    "category" => "prompt_bug",
    "step" => "work",
    "what_went_wrong" =>
      "They asked about the staging database and Ryker answered about production; the Work instructions never say to keep to the environment the person named.",
    "expected" => "Checks the staging database, not production, and says which checks it ran.",
    "confidence" => "high"
  }

  # Andrew, 2026-09-27: "we need evals building based on sentiment and
  # self-analysis without much of manual human reviews". The whole loop rests
  # on this: one unhappy request becomes one model call whose diagnosis is
  # kept, through the same frozen, keyed Coop steps learning takes.
  test "a request people were unhappy with is analyzed once, and its diagnosis is kept" do
    request = unhappy_request!("1790100100.000100")
    coop = coop!([Jason.encode!(@diagnosis)], turn_wait_polls: 2)

    results = drain(settings(coop))
    assert {:ok, :analyzed} in results

    candidate = Improvement.for_request(request)
    assert candidate.analysis == :done
    assert candidate.category == :prompt_bug
    assert candidate.step == :work
    assert candidate.confidence == :high
    assert candidate.what_went_wrong == @diagnosis["what_went_wrong"]
    assert candidate.expected == @diagnosis["expected"]
    assert candidate.start_count == 1
    assert is_nil(candidate.lease_ref)

    # The model saw the exact words, under the strict contract.
    assert [submission] = FakeCoopAPI.state(coop).submissions
    assert submission["contract_version"] == Prompt.contract_version()
    assert submission["output_schema"] == Prompt.output_schema()
    assert submission["prompt"] =~ "Is the staging database healthy?"
    assert submission["prompt"] =~ "The production database is healthy"
    assert submission["prompt"] =~ "They are upset that Ryker checked production"

    # One create and one submit: every retry of a step found its key.
    state = FakeCoopAPI.state(coop)
    assert length(state.create_keys) == 1
    assert length(state.turn_keys) == 1

    # The run stopped with proof, so cleanup may close its session, and the
    # turn is metered.
    [run] = Repo.all(from(run in AnalysisRun, where: run.candidate_id == ^candidate.id))
    assert run.status == :applied
    assert %DateTime{} = run.remote_stopped_at
    assert candidate.analysis_run_id == run.id

    session = Repo.get_by!(Session, execution_kind: :improvement, improvement_run_id: run.id)

    assert Repo.exists?(
             from([session: eligible] in RetentionCustody.eligible_query(DateTime.utc_now()),
               where: eligible.id == ^session.id
             )
           )

    assert Repo.exists?(
             from(execution in Execution,
               where: execution.kind == "improvement" and execution.source_id == ^run.id
             )
           )

    # Analyzed once: nothing is left to claim.
    assert Dispatcher.run_once(settings(coop)) == {:ok, :idle}
  end

  # Analyzing a request whose Work is still answering reads half a story, and
  # a burst of feedback (a thumbs down, the same question again, an angry
  # reply) read three times costs three model calls for one problem.
  test "waits for the request's Work to rest and for a quiet time after its latest negative feedback" do
    # Answered first: the fixture's Work claims the next turn it can.
    quiet = unhappy_request!("1790100200.000100")
    candidate = Improvement.for_request(quiet)

    Repo.update_all(from(c in Candidate, where: c.id == ^candidate.id),
      set: [last_signal_at: DateTime.utc_now()]
    )

    running = running_request!()
    record!(running, :reaction_added, "-1", nil, "busy-1", @now)
    coop = coop!([Jason.encode!(@diagnosis)])

    # Quiet time over for the running one, not yet for the other.
    waiting = Map.put(settings(coop), :quiet_seconds, 300)
    assert Dispatcher.run_once(waiting) == {:ok, :idle}
    assert Improvement.for_request(running).analysis == :pending

    # The worker sleeps until exactly then: a due time, as a UTC DateTime,
    # whatever shape the database's aggregate came back in.
    due = Analyses.next_due_at(DateTime.add(DateTime.utc_now(), -1, :second), waiting)
    assert %DateTime{time_zone: "Etc/UTC"} = due
    assert DateTime.diff(due, DateTime.utc_now()) in 290..300

    assert FakeCoopAPI.state(coop).create_keys == []
  end

  # The host checks the answer against the contract before it tells Coop to
  # accept it, as learning does. A failed check spends the start, never a
  # second call in the same turn, and the next start is told what went wrong.
  test "an answer that fails the host's check ends that start, and the next start is told so" do
    request = unhappy_request!("1790100300.000100")
    invalid = Jason.encode!(Map.put(@diagnosis, "confidence", 3))
    coop = coop!([invalid, Jason.encode!(@diagnosis)])

    results = drain(settings(coop))
    assert {:ok, :analyzed} in results

    candidate = Improvement.for_request(request)
    assert candidate.analysis == :done
    assert candidate.start_count == 2

    [first, second] =
      Repo.all(
        from(run in AnalysisRun,
          where: run.candidate_id == ^candidate.id,
          order_by: run.generation
        )
      )

    assert first.status == :rejected
    assert first.error_code == "invalid_improvement_result"
    assert %DateTime{} = first.remote_stopped_at
    assert second.status == :applied

    [first_submission, second_submission] = FakeCoopAPI.state(coop).submissions
    refute first_submission["prompt"] =~ "did not match the output contract"
    assert second_submission["prompt"] =~ "did not match the output contract"

    # Coop was never told to accept the answer that failed the check.
    assert Enum.map(FakeCoopAPI.state(coop).validations, & &1.verdict) == [:accept]
  end

  test "a model that keeps failing costs at most three starts, then the candidate says so" do
    request = unhappy_request!("1790100400.000100")
    coop = coop!(List.duplicate(Jason.encode!(@diagnosis), 5), every_turn_state: "failed")

    drain(settings(coop), 40)

    candidate = Improvement.for_request(request)
    assert candidate.analysis == :failed
    assert candidate.error_code == "improvement_retry_exhausted"
    assert candidate.start_count == 3
    assert length(FakeCoopAPI.state(coop).turn_keys) == 3
    assert Dispatcher.run_once(settings(coop)) == {:ok, :idle}
  end

  test "a candidate dismissed before Ryker got to it costs no model call" do
    request = unhappy_request!("1790100500.000100")
    candidate = Improvement.for_request(request)
    assert {:ok, _dismissed} = Improvement.dismiss(candidate.id, "control-plane:local")
    coop = coop!([Jason.encode!(@diagnosis)])

    assert Dispatcher.run_once(settings(coop)) == {:ok, :idle}
    assert FakeCoopAPI.state(coop).create_keys == []
  end

  # Retained messages go only to an isolated, read-only scratch session.
  test "a session that is more than a read-only scratch is never told anything" do
    request = unhappy_request!("1790100600.000100")
    coop = coop!([Jason.encode!(@diagnosis)], repository_read_only: false)

    drain(settings(coop))

    assert Map.get(FakeCoopAPI.state(coop), :submissions, []) == []
    candidate = Improvement.for_request(request)
    [run] = Repo.all(from(run in AnalysisRun, where: run.candidate_id == ^candidate.id))
    assert run.error_code == "improvement_session_not_isolated"
    assert run.stop_receipt["kind"] == "never_submitted"
    assert Analyses.policy_refused?(settings(coop))
    assert candidate.analysis == :pending
  end

  defp settings(coop) do
    %{
      api: API,
      client: coop,
      policy: "ryker-learning",
      policy_digest: String.duplicate("a", 64),
      worker_ref: "improvement-test",
      concurrency: 1,
      quiet_seconds: 0,
      poll_interval_ms: 100,
      execution_timeout_seconds: 600,
      lease_seconds: 300,
      step_delay_seconds: 0,
      retry_delay_seconds: 0
    }
  end

  defp coop!(answers, options \\ []) do
    {:ok, coop} =
      FakeCoopAPI.start_link(
        answers,
        Keyword.merge(
          [async_create: true, async_submit: true, async_operations_running: true],
          options
        )
      )

    coop
  end

  # Runs the queue until it has nothing to do, as the worker would.
  defp drain(settings, limit \\ 20) do
    Enum.reduce_while(1..limit, [], fn _pass, results ->
      case Dispatcher.run_once(settings) do
        {:ok, :idle} = idle -> {:halt, results ++ [idle]}
        result -> {:cont, results ++ [result]}
      end
    end)
  end

  defp unhappy_request!(ts) do
    question =
      Answers.slack_message!(
        workspace: @workspace,
        channel: "CSTAGING",
        actor: "UBOB",
        text: "Is the staging database healthy?",
        ts: ts
      )

    reply =
      Answers.work_reply!(
        question,
        "The production database is healthy: replication lag is under a second.",
        String.replace(ts, ".000100", ".000200"),
        DateTime.add(@now, 60, :second)
      )

    request = {:episode, reply.episode.id}

    record!(
      request,
      :sentiment,
      "angry",
      "They are upset that Ryker checked production instead of staging.",
      "angry-#{ts}",
      DateTime.add(@now, 180, :second)
    )

    request
  end

  # An episode whose Work is still to run: admitted, pinned to a session,
  # with no answer yet.
  defp running_request! do
    id = Ecto.UUID.generate()

    assert {:ok, _admitted} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: id,
                 episode_key: "improvement-running:#{id}",
                 native_input_id: "improvement-running:#{id}",
                 occurred_at: @now,
                 turn_ref: "turn:improvement-running:#{id}"
               })
             )

    assert {:ok, _session} = Custody.pin_episode(id, "answers", String.duplicate("a", 64))
    {:episode, id}
  end

  defp record!(request, kind, value, note, event, at) do
    assert {:ok, _recorded} =
             Feedback.record(%{
               kind: kind,
               value: value,
               note: note,
               actor_ref: "UBOB",
               source: "slack",
               source_ref: "slack-event:#{event}",
               occurred_at: at,
               request: request
             })
  end
end
