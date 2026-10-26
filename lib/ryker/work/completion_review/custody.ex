defmodule Ryker.Work.CompletionReview.Custody do
  @moduledoc "Review custody is fenced by its parent Work lease; no provider calls run in transactions."
  @behaviour Ryker.Coop.RunStep.Store
  alias Ryker.{CanonicalJSON, Coop, Crypto, Reference, Repo}
  alias Ryker.Work.CompletionReview.{Evidence, FleetSession, Prompt, Run}
  alias Ryker.Work.Custody
  alias Ryker.Work.Custody.Locks
  alias Ryker.Work.{FinalPreflight, Session}

  @terminal ~w(completed failed cancelled interrupted budget_exhausted)
  @maximum_reviews 12
  @maximum_unchanged 3

  @doc "Freeze or reuse the exact candidate/evidence review; exhaustion never authorizes acceptance."
  def prepare(claim, snapshot) do
    with_lease(claim, fn ->
      {parent, turn} = Locks.leased!(claim.episode.id, claim.turn.turn_ref, claim.lease_ref)
      candidate_sha = FinalPreflight.candidate_sha256(snapshot["candidate"])
      ledger_sha = snapshot["ledger_sha256"]
      current_ledger = Evidence.fingerprint(%{claim | session: parent, turn: turn})
      unless ledger_sha == current_ledger, do: Repo.rollback(:completion_review_evidence_changed)
      runs = Repo.all(Run.Query.ordered_by_generation(Run.Query.by_turn_id(turn.id)))

      case Enum.find(runs, &is_nil(&1.remote_stopped_at)) do
        %Run{} = run -> {:ok, run}
        nil -> prepare_stopped(runs, turn, parent, candidate_sha, ledger_sha, snapshot)
      end
    end)
  end

  defp prepare_stopped(runs, turn, parent, candidate_sha, ledger_sha, snapshot) do
    existing =
      Enum.find(
        Enum.reverse(runs),
        &(&1.candidate_sha256 == candidate_sha and &1.ledger_sha256 == ledger_sha and
            &1.status == :applied)
      )

    unchanged = Enum.count(runs, &(&1.progress_sha256 == snapshot["progress_sha256"]))

    cond do
      existing ->
        {:ok, existing}

      length(runs) >= @maximum_reviews or unchanged >= @maximum_unchanged ->
        {:error, :completion_review_budget_exhausted}

      true ->
        prompt =
          Prompt.build(
            Map.put(
              snapshot,
              "previous_reviews",
              CanonicalJSON.bounded(prior_reviews(runs, ledger_sha), 12_000)
            )
          )

        attributes = %{
          id: Repo.generate_id(),
          turn_id: turn.id,
          generation: length(runs) + 1,
          candidate_sha256: candidate_sha,
          ledger_sha256: ledger_sha,
          progress_sha256: snapshot["progress_sha256"],
          policy: parent.policy,
          policy_digest: parent.policy_digest,
          prompt: prompt,
          prompt_sha256: Crypto.sha256_hex(prompt),
          output_schema: Prompt.schema(),
          started_at: Repo.now!()
        }

        with {:ok, run} <- Repo.insert(Run.Changeset.insert(attributes)),
             {:ok, _session} <- FleetSession.ensure(run, parent),
             do: {:ok, run}
    end
  end

  defp prior_reviews(runs, ledger_sha) do
    runs
    |> Enum.filter(&(&1.ledger_sha256 == ledger_sha))
    |> Enum.take(-3)
    |> Enum.flat_map(fn run ->
      case Prompt.parse(run.result) do
        {:ok, review} -> [review]
        {:error, _invalid} -> []
      end
    end)
  end

  @doc "Apply only an exact accepted review's scoped correction to the current candidate."
  def apply_feedback(claim, id, final) do
    transaction(claim, id, fn run ->
      unless run.status == :applied and
               run.candidate_sha256 ==
                 FinalPreflight.candidate_sha256(Ryker.Work.Final.document(final)) and
               run.ledger_sha256 == Evidence.fingerprint(claim),
             do: Repo.rollback(:completion_review_evidence_changed)

      {:ok, judgment} = Prompt.parse(run.result)
      refs = judgment["dismiss_wait_refs"]

      unless Enum.all?(refs, &(&1 in final.record_refs)),
        do: Repo.rollback(:completion_review_invalid_wait)

      :ok =
        Ryker.Records.dismiss_reviewed_waits_in_transaction(claim.episode.id, claim.turn.id, refs)

      run
    end)
  end

  @doc "The parent's unfinished child, for cancellation before releasing parent custody."
  def outstanding(turn_id) do
    turn_id |> Run.Query.by_turn_id() |> Repo.all() |> Enum.find(&is_nil(&1.remote_stopped_at))
  end

  @impl true
  def current(id), do: Repo.fetch!(Run.Query.by_id(id))

  @impl true
  def renew(claim, seconds),
    do: Custody.renew(claim.episode.id, claim.turn.turn_ref, claim.lease_ref, seconds)

  @impl true
  def with_lease(claim, callback) do
    Repo.transaction(fn ->
      _turn = fetch_and_lock_owned_in_transaction!(claim)

      case callback.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @impl true
  def fetch_and_lock_owned_in_transaction!(claim) do
    {_session, turn} = Locks.leased!(claim.episode.id, claim.turn.turn_ref, claim.lease_ref)
    turn
  end

  @impl true
  def operation_key(%Run{id: id}, phase), do: "ryker:completion-review:#{phase}:#{id}"

  @impl true
  def freeze_submit(claim, id, revision) do
    transaction(claim, id, fn run ->
      unless run.ledger_sha256 == Evidence.fingerprint(claim),
        do: Repo.rollback(:completion_review_evidence_changed)

      cond do
        run.submit_revision == revision ->
          run

        not is_nil(run.submit_revision) ->
          Repo.rollback(:completion_review_submission_conflict)

        run.status != :prepared or not is_nil(run.remote_stopped_at) ->
          Repo.rollback(:completion_review_finished)

        true ->
          save(run, %{submit_revision: revision})
      end
    end)
  end

  @impl true
  def bind_turn(claim, id, session_id, turn_id) do
    transaction(claim, id, fn run ->
      unless owned_session?(run, session_id) and Reference.valid?(turn_id, 1_024),
        do: Repo.rollback(:completion_review_remote_identity_conflict)

      case run.coop_turn_id do
        nil -> save(run, %{coop_turn_id: turn_id})
        ^turn_id -> run
        _other -> Repo.rollback(:completion_review_remote_identity_conflict)
      end
    end)
  end

  @impl true
  def record_candidate(claim, id, turn, producer) do
    with {:ok, result, digest, attempt} <- Coop.Documents.candidate(turn["candidate"]),
         true <- byte_size(result) <= 524_288 do
      keep_candidate(claim, id, turn, result, digest, attempt, producer)
    else
      _invalid -> {:error, :invalid_completion_review}
    end
  end

  defp keep_candidate(claim, id, turn, result, digest, attempt, producer) do
    transaction(claim, id, fn run ->
      exact_turn!(run, turn)

      cond do
        run.result == result and run.candidate_attempt == attempt ->
          run

        run.status in [:prepared, :responded] ->
          save(run, %{
            status: :responded,
            result: result,
            result_sha256: digest,
            candidate_attempt: attempt,
            producer: producer
          })

        true ->
          Repo.rollback(:completion_review_finished)
      end
    end)
  end

  @impl true
  def confirm_candidate(claim, id, turn) do
    transaction(claim, id, fn run ->
      exact_turn!(run, turn)
      unless accepted?(run, turn), do: Repo.rollback(:completion_review_validation_unconfirmed)

      receipt =
        Map.take(
          turn,
          ~w(id session_id validation_attempt validation_candidate_sha256 validation_receipt)
        )

      if run.validation_receipt in [nil, receipt],
        do: save(run, %{validation_receipt: receipt}),
        else: Repo.rollback(:completion_review_validation_conflict)
    end)
  end

  @impl true
  def apply_result(claim, id, turn) do
    transaction(claim, id, fn run ->
      exact_turn!(run, turn)

      unless run.status in [:responded, :applied] and is_map(run.validation_receipt) and
               accepted?(run, turn),
             do: Repo.rollback(:completion_review_validation_unconfirmed)

      stop(run, Coop.Documents.terminal_receipt(turn), %{status: :applied})
    end)
  end

  defp accepted?(run, turn) do
    turn["state"] == "completed" and turn["assistant_message"] == run.result and
      turn["validation_attempt"] == run.candidate_attempt and
      turn["validation_candidate_sha256"] == run.result_sha256 and
      Reference.valid?(turn["validation_receipt"], 1_024)
  end

  @impl true
  def end_attempt(claim, id, reason) do
    transaction(claim, id, fn run ->
      if run.status in [:prepared, :responded],
        do: save(run, %{status: :rejected, error_code: Atom.to_string(reason)}),
        else: run
    end)
  end

  @impl true
  def record_stop(claim, id, %{"state" => state} = turn) when state in @terminal do
    transaction(claim, id, fn run ->
      exact_turn!(run, turn)
      stop(run, Coop.Documents.terminal_receipt(turn))
    end)
  end

  def record_stop(_claim, _id, _turn), do: {:error, :completion_review_remote_not_stopped}

  @impl true
  def fail(claim, id, reason, %{"state" => state} = turn) when state in @terminal do
    transaction(claim, id, fn run ->
      exact_turn!(run, turn)

      stop(run, Coop.Documents.failure_receipt(turn), %{
        status: :rejected,
        error_code: Atom.to_string(reason)
      })
    end)
  end

  @impl true
  def record_unsubmitted_stop(claim, id, session_id) do
    transaction(claim, id, fn run ->
      unless run.status in [:stale, :rejected] and is_nil(run.coop_turn_id) and
               owned_session?(run, session_id),
             do: Repo.rollback(:completion_review_absence_unconfirmed)

      stop(run, %{"kind" => "never_submitted", "session_id" => session_id})
    end)
  end

  @impl true
  def record_unaddressable_stop(claim, id, code) do
    transaction(claim, id, fn run ->
      unless run.status in [:stale, :rejected] and is_nil(run.submit_revision) and
               is_nil(run.coop_turn_id),
             do: Repo.rollback(:completion_review_absence_unconfirmed)

      stop(run, %{"kind" => "never_submitted", "reason" => code})
    end)
  end

  @impl true
  def record_uncreated_stop(claim, id) do
    transaction(claim, id, fn run ->
      {:ok, session} = FleetSession.fetch_for_run(run)

      unless run.status in [:stale, :rejected] and is_nil(run.coop_turn_id) and
               is_nil(session.coop_session_id),
             do: Repo.rollback(:completion_review_absence_unconfirmed)

      stop(run, %{"kind" => "never_created"})
    end)
  end

  @impl true
  def record_failed_operation(claim, id, phase, operation) do
    transaction(claim, id, fn run ->
      method = if phase == :create, do: "CreateRemoteSession", else: "SubmitTurn"

      unless is_nil(run.coop_turn_id) and operation["method"] == method and
               operation["state"] == "failed" and is_nil(operation["resource_id"]) and
               Reference.valid?(operation["id"], 1_024),
             do: Repo.rollback(:completion_review_absence_unconfirmed)

      receipt = %{
        "kind" => "failed_operation",
        "phase" => Atom.to_string(phase),
        "operation_id" => operation["id"]
      }

      stop(run, receipt, %{status: :rejected, error_code: "completion_review_worker_refused"})
    end)
  end

  @impl true
  def record_expired_stop(claim, id, seconds) do
    transaction(claim, id, fn run ->
      unless Repo.passed?(run.started_at, seconds),
        do: Repo.rollback(:completion_review_remote_unresolved)

      stop(run, %{"kind" => "attempt_expired", "closed_after_seconds" => seconds}, %{
        status: :rejected,
        error_code: "completion_review_expired"
      })
    end)
  end

  @doc "Permanent removal fences even a submitted child; recheck its exact placement under the parent lease."
  def stop_removed_worker(claim, id) do
    transaction(claim, id, fn run ->
      {:ok, session} = FleetSession.fetch_for_run(run)

      with {:ok, worker_id} <- Ryker.Work.Custody.Cancellation.removed_worker(session.id),
           {:ok, receipt} <-
             Ryker.Work.Cancellation.worker_removed_receipt(
               session.coop_session_id,
               run.coop_turn_id,
               worker_id
             ) do
        stop(run, receipt, %{status: :rejected, error_code: "completion_review_worker_removed"})
      else
        _present -> Repo.rollback(:completion_review_worker_not_removed)
      end
    end)
  end

  defp transaction(claim, id, callback) do
    Repo.transaction(fn ->
      turn = fetch_and_lock_owned_in_transaction!(claim)

      query =
        id |> Run.Query.by_id() |> Run.Query.by_turn_id(turn.id) |> Run.Query.lock_for_update()

      run = Repo.peek(query) || Repo.rollback(:completion_review_owner_mismatch)
      callback.(run)
    end)
  end

  defp owned_session?(run, remote_id) do
    case FleetSession.fetch_for_run(run) do
      {:ok, %Session{coop_session_id: ^remote_id}} -> Reference.valid?(remote_id, 1_024)
      _other -> false
    end
  end

  defp exact_turn!(run, turn) do
    unless run.coop_turn_id == turn["id"] and owned_session?(run, turn["session_id"]),
      do: Repo.rollback(:completion_review_remote_identity_conflict)
  end

  defp stop(run, receipt, attributes \\ %{}) do
    cond do
      run.stop_receipt == receipt ->
        run

      not is_nil(run.stop_receipt) ->
        Repo.rollback(:completion_review_stop_conflict)

      true ->
        save(run, Map.merge(attributes, %{stop_receipt: receipt, remote_stopped_at: Repo.now!()}))
    end
  end

  defp save(run, attributes), do: run |> Run.Changeset.transition(attributes) |> Repo.update!()
end
