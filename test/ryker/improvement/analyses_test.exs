defmodule Ryker.Improvement.AnalysesTest do
  use Ryker.DataCase, async: false
  import Ecto.Query
  alias Ryker.Accounting.Execution
  alias Ryker.Episodes
  alias Ryker.Feedback
  alias Ryker.Fixtures.Answers
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Improvement
  alias Ryker.Improvement.{Analyses, AnalysisRun, Candidate, Dispatcher, Prompt}
  alias Ryker.Inspectors
  alias Ryker.Records.Record
  alias Ryker.Retention.Cleanup
  alias Ryker.Retention.Custody, as: RetentionCustody
  alias Ryker.TestSupport.FakeCoopAPI
  alias Ryker.Work.{Session, Turn}

  @workspace "TIMPROVEANALYSES"
  @now ~U[2026-09-27 12:00:00.000000Z]

  # The fleet answers every Coop mutation with an operation still running
  # and the worker finishes it a moment later (the fake's asynchronous mode);
  # a fake that answered at once would prove nothing about waiting.
  defmodule API do
    alias Ryker.TestSupport.FakeCoopAPI, as: Fake

    defdelegate prepare_create_session(client, key, policy, ref, source), to: Fake
    defdelegate create_session(client, key, policy, ref, source), to: Fake
    defdelegate get_turn(client, session_id, turn_id), to: Fake
    defdelegate cancel_turn(client, session_id, turn_id, key, revision), to: Fake

    # What the fleet says of every session while a test sets `:session_answer`.
    def get_session(client, id) do
      case Agent.get(client, &Map.get(&1, :session_answer)) do
        nil -> Fake.get_session(client, id)
        answer -> answer
      end
    end

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

    candidate = Inspectors.improvement_candidate(request)
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

    session = Repo.get_by!(Session, execution_kind: :improvement, improvement_run_id: run.id)

    assert Repo.exists?(
             DateTime.utc_now()
             |> Cleanup.Query.eligible()
             |> Session.Query.by_id(session.id)
           )

    # Cleanup claims it under its run, as it claims a learning session under
    # its learning run (the request's own Work session is not this test's).
    work_sessions =
      Repo.all(from(s in Session, where: s.episode_id == ^elem(request, 1), select: s.id))

    assert {:ok, %{owner: %AnalysisRun{id: owner}, session: %Session{id: claimed}}} =
             RetentionCustody.claim_next("improvement-cleanup", 60, session_ids: work_sessions)

    assert {owner, claimed} == {run.id, session.id}

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
    candidate = Inspectors.improvement_candidate(quiet)

    Repo.update_all(from(c in Candidate, where: c.id == ^candidate.id),
      set: [last_signal_at: DateTime.utc_now()]
    )

    running = running_request!()
    record!(running, :reaction_added, "-1", nil, "busy-1", @now)
    coop = coop!([Jason.encode!(@diagnosis)])

    # Quiet time over for the running one, not yet for the other.
    waiting = Map.put(settings(coop), :quiet_seconds, 300)
    assert Dispatcher.run_once(waiting) == {:ok, :idle}
    assert Inspectors.improvement_candidate(running).analysis == :pending

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

    candidate = Inspectors.improvement_candidate(request)
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

  # The host keeps an offered answer only in the shape Coop promises: at
  # most 64 KB, a whole attempt number, a digest that matches. One that was
  # not came back as a Coop step still to settle, so the run read the same
  # turn again, backing off to once a minute, for a day until it expired,
  # and held the candidate's only lease all that time (found in review,
  # 2026-09-28). It fails the host's check like an answer outside the
  # contract: that start is spent, its turn is cancelled, and the next start
  # is told so.
  test "an offered answer the host cannot keep ends that start instead of being read again for a day" do
    request = unhappy_request!("1790101400.000100")

    novel =
      Jason.encode!(%{
        @diagnosis
        | "what_went_wrong" => String.duplicate("It went wrong. ", 5_000)
      })

    assert byte_size(novel) > 65_536
    coop = coop!([novel, Jason.encode!(@diagnosis)])

    drain(settings(coop))

    candidate = Inspectors.improvement_candidate(request)
    [first | _later] = runs(candidate)

    assert {first.status, first.error_code} == {:rejected, "invalid_improvement_result"},
           "the run is still waiting to read the answer it cannot keep " <>
             "(#{first.reconcile_attempt_count} failed reads so far)"

    assert %{"kind" => "terminal_turn", "state" => "cancelled"} = first.stop_receipt
    assert candidate.analysis == :done
    assert candidate.start_count == 2

    # Coop was never told to accept it, and the next start heard why.
    assert Enum.map(FakeCoopAPI.state(coop).validations, & &1.verdict) == [:accept]
    assert [_first, second] = FakeCoopAPI.state(coop).submissions
    assert second["prompt"] =~ "did not match the output contract"
  end

  # Repository knowledge learned to say why a step keeps failing (ffac2d7b);
  # analyses, run the same way, retried their step in silence (2026-10-04
  # review).
  test "an analysis step that keeps failing says why in the log" do
    unhappy_request!("1790101900.000100")
    coop = coop!([Jason.encode!(@diagnosis)])
    assert {:ok, _yielded} = Dispatcher.run_once(settings(coop))
    Agent.update(coop, &Map.put(&1, :session_answer, {:error, :unreachable}))

    log = ExUnit.CaptureLog.capture_log(fn -> drain(settings(coop), 4) end)

    assert log =~ "analysis could not take its next step"
    assert log =~ "unreachable"
  end

  test "a model that keeps failing costs at most three starts, then the candidate says so" do
    request = unhappy_request!("1790100400.000100")
    coop = coop!(List.duplicate(Jason.encode!(@diagnosis), 5), every_turn_state: "failed")

    drain(settings(coop), 40)

    candidate = Inspectors.improvement_candidate(request)
    assert candidate.analysis == :failed
    assert candidate.error_code == "improvement_retry_exhausted"
    assert candidate.start_count == 3
    assert length(FakeCoopAPI.state(coop).turn_keys) == 3
    assert Dispatcher.run_once(settings(coop)) == {:ok, :idle}
  end

  test "a candidate dismissed before Ryker got to it costs no model call" do
    request = unhappy_request!("1790100500.000100")
    candidate = Inspectors.improvement_candidate(request)
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
    candidate = Inspectors.improvement_candidate(request)
    [run] = Repo.all(from(run in AnalysisRun, where: run.candidate_id == ^candidate.id))
    assert run.error_code == "improvement_session_not_isolated"
    assert run.stop_receipt["kind"] == "never_submitted"
    assert Analyses.policy_refused?(settings(coop))
    assert candidate.analysis == :pending
  end

  # The worker can close a session before the turn meant for it is sent; a
  # prompt is never sent to a session that cannot take it, and the next start
  # gets a session of its own.
  test "a session closed before its turn was sent is given up, and the next start makes another" do
    request = unhappy_request!("1790100800.000100")
    coop = coop!([Jason.encode!(@diagnosis)])

    assert {:ok, _yielded} = Dispatcher.run_once(settings(coop))
    Agent.update(coop, &put_in(&1, [:session, "state"], "closed"))
    drain(settings(coop))

    candidate = Inspectors.improvement_candidate(request)
    assert candidate.analysis == :done
    assert candidate.start_count == 2

    [closed, fresh] =
      Repo.all(
        from(run in AnalysisRun,
          where: run.candidate_id == ^candidate.id,
          order_by: run.generation
        )
      )

    assert closed.error_code == "improvement_session_unaddressable"
    assert closed.stop_receipt["kind"] == "never_submitted"
    assert fresh.status == :applied
    assert length(FakeCoopAPI.state(coop).submissions) == 1
  end

  # The fleet never replaces a session whose worker went away. Before this,
  # a run whose worker left between the create and the submit asked Coop
  # again every minute for a day, then started over anyway (found in review,
  # 2026-09-27). No turn was sent, so there is nothing to wait for.
  test "a session its worker left before the turn was sent is given up at once, and the next start makes another" do
    request = unhappy_request!("1790101000.000100")
    coop = coop!([Jason.encode!(@diagnosis)])

    Agent.update(
      coop,
      &Map.put(&1, :session_answer, {:error, {:coop_session_replacement_required, "gone", 1}})
    )

    Enum.reduce_while(1..5, nil, fn _pass, _ ->
      assert {:ok, _result} = Dispatcher.run_once(settings(coop))
      if stopped_run(request), do: {:halt, nil}, else: {:cont, nil}
    end)

    gone = stopped_run(request)
    assert gone, "the run still waits for a session no worker holds"
    assert gone.error_code == "improvement_session_unaddressable"

    assert %{"kind" => "never_submitted", "session" => "unaddressable"} = gone.stop_receipt
    assert gone.stop_receipt["reason"] == "coop_session_replacement_required"
    assert Map.get(FakeCoopAPI.state(coop), :submissions, []) == []

    Agent.update(coop, &Map.delete(&1, :session_answer))
    drain(settings(coop))

    candidate = Inspectors.improvement_candidate(request)
    assert candidate.analysis == :done
    assert candidate.start_count == 2
    assert length(FakeCoopAPI.state(coop).submissions) == 1
  end

  # Self-analysis runs on learning's switch. Turned off, its lane used to
  # stop outright, so an analysis already out at Coop never got stop proof:
  # its session stayed open and the words in its prompt outlived their
  # horizon until learning came back on (found in review, 2026-09-27).
  test "with learning off, an analysis already out at Coop finishes and no other starts" do
    out = unhappy_request!("1790101100.000100")
    coop = coop!([Jason.encode!(@diagnosis)])
    assert {:ok, _yielded} = Dispatcher.run_once(settings(coop))
    waiting = unhappy_request!("1790101200.000100")

    off = %{settings(coop) | enabled: false}
    drain(off)

    assert Inspectors.improvement_candidate(out).analysis == :done
    assert Inspectors.improvement_candidate(waiting).analysis == :pending
    assert length(FakeCoopAPI.state(coop).create_keys) == 1
    assert Dispatcher.run_once(off) == {:ok, :idle}

    # Nothing but the clock of what is out wakes it while learning is off.
    assert Analyses.next_due_at(DateTime.add(DateTime.utc_now(), -3_600, :second), off) == nil
  end

  # A deploy restarts the worker whenever it likes. One that landed after an
  # accepted answer's stop proof was saved and before its diagnosis left the
  # run looking finished with nothing kept: the next start paid for a second
  # model call and, on the last start, gave up with a valid answer on record
  # (found in review, 2026-09-27). The lease running out at that moment is
  # the same restart, as the next worker sees it.
  test "an accepted answer's diagnosis is kept with the proof its turn stopped, or neither is" do
    request = unhappy_request!("1790100900.000100")
    coop = coop!([Jason.encode!(@diagnosis), Jason.encode!(@diagnosis)])
    lose_lease_once_stop_proof_is_written!(Inspectors.improvement_candidate(request).id)

    drain(settings(coop))

    candidate = Inspectors.improvement_candidate(request)
    assert candidate.analysis == :done
    assert candidate.what_went_wrong == @diagnosis["what_went_wrong"]
    assert candidate.start_count == 1
    assert length(FakeCoopAPI.state(coop).submissions) == 1

    assert [%AnalysisRun{status: :applied, remote_stopped_at: %DateTime{}}] =
             Repo.all(from(run in AnalysisRun, where: run.candidate_id == ^candidate.id))
  end

  # A GitHub request's words are the body of the comment or review its
  # webhook carried, not a text field. Read as Slack messages are, every
  # GitHub request an operator stopped failed its analysis, and the page
  # said the person's messages were deleted or had expired.
  test "a GitHub request is analyzed from the words of its comment" do
    comment = "@ryker the payments export failed again on PR 42, why?"
    request = github_request!(body: comment)
    coop = coop!([Jason.encode!(@diagnosis)])

    drain(settings(coop))

    candidate = Inspectors.improvement_candidate(request)
    assert {candidate.analysis, candidate.error_code} == {:done, nil}
    assert candidate.reasons == ["rated"]
    assert [submission] = FakeCoopAPI.state(coop).submissions
    assert submission["prompt"] =~ "the payments export failed again on PR 42, why?"
    assert submission["prompt"] =~ ~s("channel":"github")
  end

  # "Deleted or expired" is only one way to have nothing to read. A review
  # submitted without a word, or a request an alert started with no person
  # in it, says what is really missing, and no model is asked.
  test "a request with none of a person's words says why it was not analyzed" do
    wordless = github_request!(body: nil, review: true)
    automated = automated_request!("1790101300.000100")
    coop = coop!([Jason.encode!(@diagnosis)])

    drain(settings(coop))

    assert {Inspectors.improvement_candidate(wordless).analysis,
            Inspectors.improvement_candidate(wordless).error_code} ==
             {:failed, "improvement_evidence_wordless"}

    assert {Inspectors.improvement_candidate(automated).analysis,
            Inspectors.improvement_candidate(automated).error_code} ==
             {:failed, "improvement_evidence_automated"}

    assert FakeCoopAPI.state(coop).create_keys == []
  end

  # Live, 2026-09-29: Andrew rated the task behind PR #2, and it was never analyzed:
  # "improvement_evidence_automated". A confirmed task runs in an episode of its own, whose
  # inputs are the host's go-ahead and what GitHub sent; the person asked for it in the
  # conversation that offered it. No rating of any task could ever become a case.
  test "a task is analyzed from the conversation where the person asked for it" do
    asked =
      Answers.slack_message!(
        workspace: @workspace,
        channel: "CTASKS",
        actor: "UBOB",
        text: "Add a workflow smoke test section to the README, please.",
        ts: "1790101500.000100"
      )

    conversation =
      Answers.work_reply!(
        asked,
        "I can do that as a task in AndrewDryga/test.",
        "1790101500.000200",
        DateTime.add(@now, 60, :second)
      )

    task = automated_request!("1790101600.000100")
    {:episode, task_episode_id} = task
    offered!(conversation.episode.id, task_episode_id)
    coop = coop!([Jason.encode!(@diagnosis)])

    drain(settings(coop))

    candidate = Inspectors.improvement_candidate(task)
    assert {candidate.analysis, candidate.error_code} == {:done, nil}
    assert [submission] = FakeCoopAPI.state(coop).submissions
    assert submission["prompt"] =~ "Add a workflow smoke test section to the README"
  end

  # The PR #2 task's rating was refused this way before the fix, and a refused analysis never
  # starts again by itself: the migration asks such tasks again, and only them.
  test "a task refused before its conversation was read is asked again, an alert is not" do
    asked =
      Answers.slack_message!(
        workspace: @workspace,
        channel: "CTASKS",
        actor: "UBOB",
        text: "Add a workflow smoke test section to the README, please.",
        ts: "1790101700.000100"
      )

    conversation =
      Answers.work_reply!(
        asked,
        "I can do that.",
        "1790101700.000200",
        DateTime.add(@now, 60, :second)
      )

    task = automated_request!("1790101800.000100")
    {:episode, task_episode_id} = task
    offered!(conversation.episode.id, task_episode_id)
    alert = automated_request!("1790101900.000100")

    Repo.update_all(from(candidate in Candidate),
      set: [analysis: :failed, error_code: "improvement_evidence_automated"]
    )

    # The migration that asks refused tasks again is tested by the statement it
    # runs, loaded once per run with every other migration.
    {_version, migration} = List.keyfind(Ryker.TestMigrations.all(), 20_260_930_110_000, 0)
    Repo.query!(migration.requeued_tasks_sql())
    coop = coop!([Jason.encode!(@diagnosis)])

    drain(settings(coop))

    assert {Inspectors.improvement_candidate(task).analysis,
            Inspectors.improvement_candidate(task).error_code} ==
             {:done, nil}

    assert {Inspectors.improvement_candidate(alert).analysis,
            Inspectors.improvement_candidate(alert).error_code} ==
             {:failed, "improvement_evidence_automated"}
  end

  # "A person forgetting wins": a message deleted while its analysis is out
  # at Coop erases the prompt, and the run stops without ever sending it.
  test "an analysis whose prompt a person forgot while it was out stops without sending it" do
    ts = "1790100700.000100"
    request = unhappy_request!(ts)
    coop = coop!([Jason.encode!(@diagnosis)])

    # The first step asks Coop for the session, which is still being made.
    assert {:ok, _yielded} = Dispatcher.run_once(settings(coop))
    candidate = Inspectors.improvement_candidate(request)

    assert [%AnalysisRun{started_at: %DateTime{}, remote_stopped_at: nil} = run] =
             Repo.all(from(run in AnalysisRun, where: run.candidate_id == ^candidate.id))

    # A session whose run may still be busy is never cleaned up under it.
    session = Repo.get_by!(Session, execution_kind: :improvement, improvement_run_id: run.id)

    refute Repo.exists?(
             DateTime.utc_now()
             |> Cleanup.Query.eligible()
             |> Session.Query.by_id(session.id)
           )

    Answers.slack_message!(
      workspace: @workspace,
      channel: "CSTAGING",
      actor: "UBOB",
      text: "",
      ts: ts,
      kind: :delete,
      revision: 2,
      at: DateTime.add(@now, 900, :second)
    )

    assert %DateTime{} = Inspectors.improvement_candidate(request).forgotten_at
    drain(settings(coop))

    assert Map.get(FakeCoopAPI.state(coop), :submissions, []) == []
    stopped = Repo.get!(AnalysisRun, run.id)
    assert stopped.error_code == "improvement_forgotten"
    assert stopped.stop_receipt["kind"] == "never_submitted"
    assert stopped.prompt == nil

    forgotten = Inspectors.improvement_candidate(request)
    assert forgotten.analysis == :failed
    assert forgotten.error_code == "improvement_forgotten"
    assert Dispatcher.run_once(settings(coop)) == {:ok, :idle}
  end

  defp runs(candidate) do
    Repo.all(
      from(run in AnalysisRun,
        where: run.candidate_id == ^candidate.id,
        order_by: run.generation
      )
    )
  end

  defp stopped_run(request) do
    candidate = Inspectors.improvement_candidate(request)

    Repo.one(
      from(run in AnalysisRun,
        where: run.candidate_id == ^candidate.id and not is_nil(run.remote_stopped_at),
        order_by: [asc: run.generation],
        limit: 1
      )
    )
  end

  # The first time this test's process writes a run's stop proof, the
  # candidate's lease runs out, as it does for a worker that restarted there.
  defp lose_lease_once_stop_proof_is_written!(candidate_id) do
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:ryker, :repo, :query],
        &__MODULE__.lose_lease/4,
        {self(), candidate_id}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  def lose_lease(_event, _measurements, %{query: query}, {owner, candidate_id}) do
    if self() == owner and not Process.get(:lease_lost?, false) and
         String.starts_with?(query, ~s(UPDATE "improvement_analysis_runs")) and
         String.contains?(query, ~s("remote_stopped_at")) do
      Process.put(:lease_lost?, true)

      Repo.update_all(from(c in Candidate, where: c.id == ^candidate_id),
        set: [lease_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)]
      )
    end
  end

  defp settings(coop) do
    %{
      api: API,
      client: coop,
      policy: "ryker-learning",
      policy_digest: String.duplicate("a", 64),
      worker_ref: "improvement-test",
      enabled: true,
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

  # A task offered in `conversation_id`'s reply and confirmed into `task_episode_id`.
  defp offered!(conversation_id, task_episode_id) do
    turn = Repo.one!(from(turn in Turn, where: turn.episode_id == ^conversation_id))
    payload = %{"kind" => "engineering", "title" => "Workflow smoke test", "repository" => "test"}

    Repo.insert!(%Record{
      id: Ecto.UUID.generate(),
      episode_id: conversation_id,
      turn_id: turn.id,
      ref: "record:task_offer:#{Ecto.UUID.generate()}",
      operation_id: "offer-task",
      kind: "task_offer",
      status: :confirmed,
      payload: payload,
      payload_fingerprint: String.duplicate("a", 64),
      confirmed_episode_id: task_episode_id,
      confirmation_ref: "interaction:confirm-task",
      confirmed_by_actor_ref: "slack:user:UBOB",
      confirmed_at: @now
    })
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

    assert {:ok, _session} = WorkSessions.pin_episode(id, "answers", String.duplicate("a", 64))
    {:episode, id}
  end

  # A person's comment or review on a pull request, answered by Work and
  # then stopped by an operator's review.
  defp github_request!(options) do
    entry = Answers.github_message!(options)

    reply =
      Answers.work_reply!(
        entry,
        "The export retried three times and succeeded.",
        "github:issue_comment:#{System.unique_integer([:positive])}",
        DateTime.add(@now, 60, :second)
      )

    request = {:episode, reply.episode.id}

    assert {:ok, _recorded} =
             Feedback.record(%{
               kind: :reviewed,
               value: "needs_work",
               note: "It answered about the wrong run.",
               actor_ref: "control-plane:local",
               source: "control_plane",
               source_ref: "episode-review:#{Ecto.UUID.generate()}",
               occurred_at: DateTime.add(@now, 120, :second),
               request: request
             })

    request
  end

  # A request an alerting app's message started, with a thumbs down on
  # Ryker's answer and no person's message in it.
  defp automated_request!(ts) do
    alert =
      Answers.slack_message!(
        workspace: @workspace,
        channel: "CALERTS",
        actor: "B0ALERTS",
        actor_kind: :app,
        text: "CPU above 90% on db-1",
        ts: ts
      )

    reply =
      Answers.work_reply!(
        alert,
        "db-1 is busy with the nightly vacuum; nothing to do.",
        String.replace(ts, ".000100", ".000200"),
        DateTime.add(@now, 60, :second)
      )

    request = {:episode, reply.episode.id}
    record!(request, :reaction_added, "-1", nil, "alert-#{ts}", DateTime.add(@now, 120, :second))
    request
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
