defmodule Ryker.Improvement.Analyses do
  @moduledoc """
  The queue of candidates waiting for Ryker's own diagnosis, and the custody
  of each analysis run, after the learning pattern (`Ryker.Learning.Batches`,
  `Ryker.Learning`).

  A candidate is analyzed once its request has come to rest (its Work is not
  running, its quick replies are delivered or given up) and no new negative
  feedback has arrived for `quiet_seconds`, so a burst of feedback is read
  once, after it. A worker leases it; each attempt is a run with a frozen
  prompt, and starting a run spends one of the candidate's starts
  (`start_limit`), so a model that keeps failing costs a bounded number of
  calls. A run whose worker session may still be busy is resumed, never
  replaced: a new run starts only once the last one has stop proof.

  Every change a page shows is announced after the outermost commit
  (`Ryker.Improvement.subscribe_improvement/0`); a lease renewal is not.
  """

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.Delivery.RoutingResponse
  alias Ryker.Improvement
  alias Ryker.Improvement.{AnalysisRun, Candidate, Evidence, FleetSession, Prompt}
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.UTCDateTime
  alias Ryker.Work.{Custody, Session}

  @contract_failures ~w(output_contract_failed invalid_improvement_result)
  # Causes another start would meet again: they end the analysis at once.
  @stopping_reasons [:improvement_evidence_unavailable, :improvement_prompt_too_large]
  @terminal ~w(completed failed cancelled interrupted budget_exhausted)

  @type claim :: %{candidate: Candidate.t(), lease_ref: Ecto.UUID.t()}

  # -- The queue --------------------------------------------------------------------

  @doc """
  Leases the next candidate to analyze, or a leased one whose worker stopped
  renewing it: `{:ok, claim}`, or `{:ok, :idle}` with nothing to do.
  """
  @spec claim(String.t(), map()) :: {:ok, claim() | :idle} | {:error, term()}
  def claim(worker, settings) do
    Repo.transaction(fn ->
      now = Repo.now!()

      case next_candidate(now, settings.quiet_seconds, settings.enabled) do
        nil -> :idle
        candidate -> lease(candidate, worker, settings.lease_seconds, now)
      end
    end)
  end

  defp next_candidate(now, quiet_seconds, enabled?) do
    quiet = DateTime.add(now, -quiet_seconds, :second)

    Repo.one(
      from(candidate in Candidate,
        as: :candidate,
        where: ^claimable(now, quiet, enabled?),
        order_by: [asc: candidate.last_signal_at, asc: candidate.id],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"
      )
    )
  end

  # A worker stopped renewing its lease; or it is due, and either a run of it
  # is still out at Coop, or it is still wanted, quiet and at rest. With
  # learning off only what is out at Coop is followed, to its stop.
  defp claimable(now, quiet, true) do
    dynamic(
      [candidate: c],
      ^stale_lease(now) or
        (^due(now) and (exists(outstanding_parent_run()) or (^wanted(quiet) and ^at_rest())))
    )
  end

  defp claimable(now, _quiet, false),
    do:
      dynamic(
        [candidate: c],
        ^stale_lease(now) or (^due(now) and exists(outstanding_parent_run()))
      )

  defp stale_lease(now),
    do: dynamic([candidate: c], c.analysis == :running and c.lease_expires_at <= ^now)

  defp due(now),
    do:
      dynamic(
        [candidate: c],
        c.analysis == :pending and (is_nil(c.next_attempt_at) or c.next_attempt_at <= ^now)
      )

  defp wanted(quiet),
    do:
      dynamic(
        [candidate: c],
        is_nil(c.forgotten_at) and c.status != :dismissed and c.last_signal_at <= ^quiet
      )

  # The request has nothing still running: its Work has come to rest, or the
  # quick replies routing chose for the message were delivered or given up.
  defp at_rest do
    running_work =
      from(work in subquery(Custody.work_rest_query()),
        where: work.episode_id == parent_as(:candidate).episode_id and work.running
      )

    pending_replies =
      from(response in RoutingResponse,
        where: response.input_id == parent_as(:candidate).input_id and response.status == :pending
      )

    dynamic(
      [candidate: candidate],
      (not is_nil(candidate.episode_id) and not exists(running_work)) or
        (not is_nil(candidate.input_id) and not exists(pending_replies))
    )
  end

  defp outstanding_parent_run do
    from(run in AnalysisRun,
      where:
        run.candidate_id == parent_as(:candidate).id and not is_nil(run.started_at) and
          is_nil(run.remote_stopped_at)
    )
  end

  @doc """
  The earliest moment after `since` at which a candidate becomes claimable
  by the clock alone: its quiet time ends, its retry or hold ends, or the
  lease of a worker that stopped renewing it runs out. With learning off only
  what is out at Coop counts. Nil when nothing waits on the clock;
  everything else that makes one claimable is announced.
  """
  @spec next_due_at(DateTime.t(), map()) :: DateTime.t() | nil
  def next_due_at(%DateTime{} = since, settings) do
    quiet = settings.quiet_seconds
    enabled? = settings.enabled

    [quiet_due, retry_due, lease_due] =
      Repo.one(
        from(candidate in Candidate,
          as: :candidate,
          where: candidate.analysis in [:pending, :running],
          select: [
            filter(
              min(datetime_add(candidate.last_signal_at, ^quiet, "second")),
              ^enabled? and candidate.analysis == :pending and is_nil(candidate.forgotten_at) and
                candidate.status != :dismissed and
                datetime_add(candidate.last_signal_at, ^quiet, "second") > ^since
            ),
            filter(
              min(candidate.next_attempt_at),
              candidate.analysis == :pending and candidate.next_attempt_at > ^since and
                (^enabled? or exists(outstanding_parent_run()))
            ),
            filter(
              min(candidate.lease_expires_at),
              candidate.analysis == :running and candidate.lease_expires_at > ^since
            )
          ]
        )
      )

    UTCDateTime.earliest([quiet_due, retry_due, lease_due])
  end

  defp lease(candidate, worker, seconds, now) do
    candidate =
      save(candidate,
        analysis: :running,
        lease_ref: Ecto.UUID.generate(),
        lease_owner: worker,
        heartbeat_at: now,
        lease_expires_at: DateTime.add(now, seconds, :second)
      )

    %{candidate: candidate, lease_ref: candidate.lease_ref}
  end

  @doc "Extends the lease; nothing a page shows changes."
  def renew(claim, seconds) do
    Repo.transaction(fn ->
      now = Repo.now!()

      claim
      |> owned!()
      |> Ecto.Changeset.change(heartbeat_at: now, lease_expires_at: DateTime.add(now, seconds))
      |> Repo.update!()
    end)
  end

  @doc "Fences local state changes with the lease. Never call a provider inside `callback`."
  def with_lease(claim, callback) do
    Repo.transaction(fn ->
      _candidate = owned!(claim)

      case callback.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "Gives the lease back and asks to be claimed again after `delay_seconds`."
  def yield(claim, delay_seconds) when is_integer(delay_seconds) and delay_seconds in 0..600 do
    Repo.transaction(fn ->
      claim
      |> owned!()
      |> save(
        analysis: :pending,
        lease_ref: nil,
        lease_owner: nil,
        lease_expires_at: nil,
        next_attempt_at: DateTime.add(Repo.now!(), delay_seconds)
      )
    end)
  end

  @doc """
  Ends an attempt that gave no diagnosis, once nothing of it can still be
  running: the candidate waits `delay_seconds` for its next start, or, when
  every start is spent or the cause would recur, stops with the cause.
  """
  def release(claim, reason, delay_seconds) when is_atom(reason) and delay_seconds >= 0 do
    Repo.transaction(fn ->
      candidate = owned!(claim)

      case stop_code(candidate, reason) do
        nil ->
          save(candidate,
            analysis: :pending,
            error_code: Atom.to_string(reason),
            lease_ref: nil,
            lease_owner: nil,
            lease_expires_at: nil,
            next_attempt_at: DateTime.add(Repo.now!(), delay_seconds)
          )

        code ->
          stop_analysis(candidate, code)
      end
    end)
  end

  # Why the analysis stops for good, or nil when another start may follow. A
  # cause that stops it by itself keeps its name even when it also spent the
  # last start, as learning's do.
  defp stop_code(%Candidate{forgotten_at: %DateTime{}}, _reason), do: "improvement_forgotten"

  defp stop_code(_candidate, reason) when reason in @stopping_reasons,
    do: Atom.to_string(reason)

  defp stop_code(%Candidate{start_count: count, start_limit: limit}, _reason)
       when count >= limit,
       do: "improvement_retry_exhausted"

  defp stop_code(_candidate, _reason), do: nil

  @doc "Stops analyzing a candidate for good, with the cause."
  def finish_failed(claim, reason) when is_atom(reason) do
    Repo.transaction(fn -> claim |> owned!() |> stop_analysis(Atom.to_string(reason)) end)
  end

  defp stop_analysis(candidate, code) do
    save(candidate,
      analysis: :failed,
      error_code: code,
      lease_ref: nil,
      lease_owner: nil,
      lease_expires_at: nil,
      next_attempt_at: nil
    )
  end

  @doc """
  Whether the worker already gave a session of this policy more than a
  read-only scratch: every further session of it would be refused the same
  way, so analysis waits for the policy to change.
  """
  def policy_refused?(%{policy: policy, policy_digest: digest}) do
    Repo.exists?(
      from(run in AnalysisRun,
        where:
          run.policy == ^policy and run.policy_digest == ^digest and
            run.error_code == "improvement_session_not_isolated"
      )
    )
  end

  # -- Runs -------------------------------------------------------------------------

  @doc "The run of a candidate that started and has no stop proof yet, or nil."
  def outstanding(candidate_id),
    do:
      Repo.one(
        from(run in AnalysisRun,
          where:
            run.candidate_id == ^candidate_id and not is_nil(run.started_at) and
              is_nil(run.remote_stopped_at),
          order_by: [asc: run.generation],
          limit: 1
        )
      )

  @doc "A run as it is stored now."
  def current(run_id), do: Repo.get!(AnalysisRun, run_id)

  @doc """
  Freezes the next attempt: the evidence read now, rendered into the exact
  prompt and schema the turn will get. An attempt prepared earlier that never
  started goes stale; its prompt was never disclosed.
  """
  @spec prepare(claim(), map()) :: {:ok, AnalysisRun.t()} | {:error, term()}
  def prepare(claim, settings) do
    with_lease(claim, fn ->
      candidate = owned!(claim)

      if candidate.start_count >= candidate.start_limit,
        do: Repo.rollback(:improvement_retry_exhausted)

      Repo.update_all(
        from(run in AnalysisRun,
          where:
            run.candidate_id == ^candidate.id and run.status == :prepared and
              is_nil(run.started_at)
        ),
        set: [status: :stale, error_code: "improvement_attempt_replaced", updated_at: Repo.now!()]
      )

      evidence = Evidence.gather(candidate)
      unless evidence.available?, do: Repo.rollback(:improvement_evidence_unavailable)

      request = Prompt.build(evidence, retry?(candidate))
      prompt = Prompt.render(request)

      if byte_size(prompt) > Prompt.maximum_bytes() + 1_024,
        do: Repo.rollback(:improvement_prompt_too_large)

      save(candidate,
        message_keys: Enum.sort(Enum.uniq(candidate.message_keys ++ evidence.message_keys)),
        conversation_refs:
          Enum.sort(Enum.uniq(candidate.conversation_refs ++ evidence.conversation_refs))
      )

      {:ok,
       Repo.insert!(%AnalysisRun{
         id: Ecto.UUID.generate(),
         candidate_id: candidate.id,
         generation: next_generation(candidate.id),
         status: :prepared,
         policy: settings.policy,
         policy_digest: settings.policy_digest,
         prompt: prompt,
         prompt_sha256: sha256(prompt),
         output_schema: Prompt.output_schema(),
         manifest: manifest(evidence, request, prompt)
       })}
    end)
  end

  defp retry?(candidate) do
    Repo.exists?(
      from(run in AnalysisRun,
        where: run.candidate_id == ^candidate.id and run.error_code in @contract_failures
      )
    )
  end

  defp next_generation(candidate_id),
    do:
      (Repo.one(
         from(run in AnalysisRun,
           where: run.candidate_id == ^candidate_id,
           select: max(run.generation)
         )
       ) || 0) + 1

  # What went in, by count, and what was left out, beside the frozen prompt.
  defp manifest(evidence, request, prompt) do
    context = request["context"]

    %{
      "bytes" => byte_size(prompt),
      "conversation" => length(context["conversation"]),
      "routing" => length(context["routing"]),
      "routing_prompts" => Enum.count(context["routing"], &is_binary(&1["prompt"])),
      "work" => length(context["work"]),
      "feedback" => length(context["feedback"]),
      "omitted" => context["omitted"],
      "message_keys" => length(evidence.message_keys)
    }
  end

  @doc "Spends one start on the run, once, when it first begins; retries of it do not spend again."
  def begin_execution(claim, run_id) do
    Repo.transaction(fn ->
      candidate = owned!(claim)
      run = locked_run!(candidate, run_id)

      cond do
        not is_nil(run.started_at) ->
          run

        run.status != :prepared ->
          Repo.rollback(:improvement_run_mismatch)

        candidate.start_count >= candidate.start_limit ->
          Repo.rollback(:improvement_retry_exhausted)

        true ->
          save(candidate, start_count: candidate.start_count + 1)
          run |> Ecto.Changeset.change(started_at: Repo.now!()) |> Repo.update!()
      end
    end)
  end

  @doc "Counts one more failure to learn how a run ended at the worker."
  def reconciliation_failed(claim, run_id) do
    with_lease(claim, fn ->
      run = locked_run!(claim.candidate, run_id)

      {:ok,
       run
       |> Ecto.Changeset.change(reconcile_attempt_count: run.reconcile_attempt_count + 1)
       |> Repo.update!()}
    end)
  end

  @doc """
  The Coop operation key of each remote step of a run: one create, one
  submit, and a cancel per session revision.
  """
  def operation_key(%AnalysisRun{id: id}, phase) when phase in [:create, :submit, :cancel],
    do: "ryker:improvement:#{phase}:#{id}"

  @doc "Freezes the session revision the turn is submitted at, before it is sent."
  def freeze_submit(claim, run_id, revision) when is_integer(revision) and revision > 0 do
    run_transaction(claim, run_id, fn run ->
      cond do
        run.submit_revision == revision ->
          run

        not is_nil(run.submit_revision) ->
          Repo.rollback(:improvement_submission_conflict)

        is_nil(run.prompt) or run.status != :prepared or is_nil(run.started_at) or
            not is_nil(run.remote_stopped_at) ->
          Repo.rollback(:improvement_attempt_not_running)

        true ->
          run |> Ecto.Changeset.change(submit_revision: revision) |> Repo.update!()
      end
    end)
  end

  def freeze_submit(_claim, _run_id, _revision), do: {:error, :invalid_improvement_revision}

  @doc "Binds the run to the Coop turn its submission became, once."
  def bind_turn(claim, run_id, session_id, turn_id) do
    run_transaction(claim, run_id, fn run ->
      unless owned_session?(run, session_id) and Reference.valid?(turn_id, 1_024),
        do: Repo.rollback(:improvement_remote_identity_conflict)

      case run.coop_turn_id do
        nil -> run |> Ecto.Changeset.change(coop_turn_id: turn_id) |> Repo.update!()
        ^turn_id -> run
        _other -> Repo.rollback(:improvement_remote_identity_conflict)
      end
    end)
  end

  @doc "Stores the exact answer the turn offered, before anything is acknowledged or applied."
  def record_candidate(
        claim,
        run_id,
        %{
          "id" => turn_id,
          "session_id" => session_id,
          "candidate" => %{"message" => result, "sha256" => digest, "attempt" => attempt}
        },
        producer
      )
      when is_binary(result) and byte_size(result) <= 65_536 and is_integer(attempt) and
             attempt > 0 do
    answer = %{
      result: result,
      result_sha256: digest,
      producer: producer,
      candidate_attempt: attempt
    }

    if sha256(result) == digest and CanonicalJSON.validate(producer, max_bytes: 4_096) == :ok,
      do: run_transaction(claim, run_id, &save_candidate(&1, turn_id, session_id, answer)),
      else: {:error, :invalid_improvement_candidate}
  end

  def record_candidate(_claim, _run_id, _turn, _producer),
    do: {:error, :invalid_improvement_result}

  defp save_candidate(run, turn_id, session_id, answer) do
    unless run.coop_turn_id == turn_id and owned_session?(run, session_id),
      do: Repo.rollback(:improvement_remote_identity_conflict)

    cond do
      run.result == answer.result and run.candidate_attempt == answer.candidate_attempt ->
        run

      run.status in [:prepared, :responded] ->
        run
        |> Ecto.Changeset.change(Map.put(answer, :status, :responded))
        |> Repo.update!()

      true ->
        Repo.rollback(:improvement_attempt_finished)
    end
  end

  @doc "Keeps the proof that Coop accepted exactly this answer on exactly this turn."
  def confirm_candidate(claim, run_id, turn) do
    run_transaction(claim, run_id, fn run ->
      receipt =
        Map.take(
          turn,
          ~w(id session_id validation_attempt validation_candidate_sha256 validation_receipt)
        )

      cond do
        not accepted?(run, turn) -> Repo.rollback(:improvement_validation_unconfirmed)
        run.validation_receipt == receipt -> run
        not is_nil(run.validation_receipt) -> Repo.rollback(:improvement_validation_conflict)
        true -> run |> Ecto.Changeset.change(validation_receipt: receipt) |> Repo.update!()
      end
    end)
  end

  # Coop completed exactly this turn with exactly the answer the run saved,
  # at the attempt it was offered, and says so with a receipt.
  defp accepted?(run, turn) do
    turn["state"] == "completed" and turn["id"] == run.coop_turn_id and
      owned_session?(run, turn["session_id"]) and accepted_answer?(run, turn)
  end

  defp accepted_answer?(run, turn) do
    is_binary(run.result) and turn["assistant_message"] == run.result and
      turn["validation_attempt"] == run.candidate_attempt and
      turn["validation_candidate_sha256"] == run.result_sha256 and
      Reference.valid?(turn["validation_receipt"], 1_024)
  end

  @doc """
  Saves the diagnosis on the candidate and ends its analysis: the run's
  answer, confirmed by Coop, checked by the host once more. The completed
  turn's stop proof is kept and the lease given back in the same
  transaction, so a step that ends before it leaves the run outstanding and
  the next one reads the same finished turn instead of asking the model
  again.
  """
  def apply_result(claim, run_id, %{"state" => "completed"} = turn) do
    Repo.transaction(fn ->
      candidate = owned!(claim)
      run = locked_run!(candidate, run_id)
      diagnosis = confirmed_diagnosis!(run, turn)

      run =
        run
        |> Ecto.Changeset.change(status: :applied)
        |> Repo.update!()
        |> store_stop(terminal_receipt(turn))

      forgotten? = not is_nil(candidate.forgotten_at)

      save(candidate,
        analysis: :done,
        category: diagnosis.category,
        step: diagnosis.step,
        confidence: diagnosis.confidence,
        what_went_wrong: if(forgotten?, do: nil, else: diagnosis.what_went_wrong),
        expected: if(forgotten?, do: nil, else: diagnosis.expected),
        analyzed_at: Repo.now!(),
        analysis_target: target(run.producer),
        analysis_run_id: run.id,
        error_code: nil,
        lease_ref: nil,
        lease_owner: nil,
        lease_expires_at: nil,
        next_attempt_at: nil
      )
    end)
  end

  def apply_result(_claim, _run_id, _turn), do: {:error, :improvement_remote_not_stopped}

  # The run's answer as the host reads it, once Coop confirmed exactly this
  # answer on exactly this run's turn; anything else rolls the save back.
  defp confirmed_diagnosis!(run, turn) do
    diagnosis =
      case run.result && Prompt.parse(run.result) do
        {:ok, diagnosis} -> diagnosis
        _invalid -> Repo.rollback(:invalid_improvement_result)
      end

    unless run.status in [:responded, :applied] and is_map(run.validation_receipt),
      do: Repo.rollback(:improvement_validation_unconfirmed)

    unless run.coop_turn_id == turn["id"] and owned_session?(run, turn["session_id"]),
      do: Repo.rollback(:improvement_remote_identity_conflict)

    diagnosis
  end

  defp target(%{"target" => target}) when is_binary(target), do: target
  defp target(_producer), do: nil

  @doc "Ends an attempt that cannot give a diagnosis, without mistaking it for one that did."
  def end_attempt(claim, run_id, reason) when is_atom(reason) do
    run_transaction(claim, run_id, fn run ->
      cond do
        run.status == :prepared and is_nil(run.started_at) ->
          run
          |> Ecto.Changeset.change(status: :stale, error_code: Atom.to_string(reason))
          |> Repo.update!()

        run.status in [:prepared, :responded] ->
          run
          |> Ecto.Changeset.change(status: :rejected, error_code: Atom.to_string(reason))
          |> Repo.update!()

        true ->
          run
      end
    end)
  end

  @doc "Keeps the terminal state of the run's turn as its stop proof."
  def record_stop(claim, run_id, %{"state" => state, "id" => turn_id} = turn)
      when state in @terminal do
    run_transaction(claim, run_id, fn run ->
      unless run.coop_turn_id == turn_id and owned_session?(run, turn["session_id"]),
        do: Repo.rollback(:improvement_remote_identity_conflict)

      store_stop(run, terminal_receipt(turn))
    end)
  end

  def record_stop(_claim, _run_id, _turn), do: {:error, :improvement_remote_not_stopped}

  defp terminal_receipt(turn),
    do:
      turn
      |> Map.take(~w(id session_id state error_code validation_attempt))
      |> Map.put("kind", "terminal_turn")

  @doc """
  Records a terminal turn that gave no usable answer: the model's output did
  not match the contract, or the provider failed. The turn is its own stop proof.
  """
  def fail(claim, run_id, reason, %{"state" => state, "id" => turn_id} = turn)
      when reason in [:output_contract_failed, :improvement_provider_failed] and
             state in @terminal do
    run_transaction(claim, run_id, fn run ->
      unless run.coop_turn_id == turn_id and owned_session?(run, turn["session_id"]),
        do: Repo.rollback(:improvement_remote_identity_conflict)

      run =
        if run.status in [:prepared, :responded],
          do:
            run
            |> Ecto.Changeset.change(status: :rejected, error_code: Atom.to_string(reason))
            |> Repo.update!(),
          else: run

      store_stop(
        run,
        turn
        |> Map.take(~w(id session_id state error_code finished_at))
        |> Map.put("kind", "terminal_turn")
      )
    end)
  end

  @doc """
  An ended run whose turn was never submitted stops on that proof: its
  session is bound, and Coop has no submit for its key (the caller asked).
  """
  def record_unsubmitted_stop(claim, run_id, session_id) do
    run_transaction(claim, run_id, fn run ->
      unless run.status in [:stale, :rejected] and is_nil(run.coop_turn_id) and
               owned_session?(run, session_id),
             do: Repo.rollback(:improvement_absence_unconfirmed)

      store_stop(run, %{
        "kind" => "never_submitted",
        "session_id" => session_id,
        "submit_revision" => run.submit_revision
      })
    end)
  end

  @doc """
  An ended run whose turn was never sent stops on that proof once its
  session can no longer be addressed: the submit revision is frozen before
  anything is sent, and none was.
  """
  def record_unaddressable_stop(claim, run_id, reason) when is_binary(reason) do
    run_transaction(claim, run_id, fn run ->
      unless run.status in [:stale, :rejected] and is_nil(run.submit_revision) and
               is_nil(run.coop_turn_id),
             do: Repo.rollback(:improvement_absence_unconfirmed)

      session = FleetSession.for_run(run)

      store_stop(run, %{
        "kind" => "never_submitted",
        "reason" => reason,
        "session" => "unaddressable",
        "session_id" => session && session.coop_session_id
      })
    end)
  end

  @doc """
  An ended run whose session was never asked for stops on that proof: its
  session is not bound, and Coop has no create for its key (the caller
  asked).
  """
  def record_uncreated_stop(claim, run_id) do
    run_transaction(claim, run_id, fn run ->
      session = FleetSession.for_run(run)

      unless run.status in [:stale, :rejected] and is_nil(run.coop_turn_id) and
               is_nil(session && session.coop_session_id),
             do: Repo.rollback(:improvement_absence_unconfirmed)

      store_stop(run, %{"kind" => "never_created"})
    end)
  end

  @doc """
  A create or submit that Coop reports failed started nothing: no session
  or no turn exists for that key, so the run stops on that proof.
  """
  def record_failed_operation(
        claim,
        run_id,
        phase,
        %{"state" => "failed", "id" => operation_id} = operation
      )
      when phase in [:create, :submit] do
    run_transaction(claim, run_id, fn run ->
      method = if phase == :create, do: "CreateRemoteSession", else: "SubmitTurn"

      unless is_nil(run.coop_turn_id) and operation["method"] == method and
               Reference.valid?(operation_id, 1_024) and is_nil(operation["resource_id"]),
             do: Repo.rollback(:improvement_absence_unconfirmed)

      run =
        if run.status in [:prepared, :responded],
          do:
            run
            |> Ecto.Changeset.change(
              status: :rejected,
              error_code: "improvement_provider_failed"
            )
            |> Repo.update!(),
          else: run

      session = FleetSession.for_run(run)

      store_stop(run, %{
        "kind" => "failed_operation",
        "phase" => Atom.to_string(phase),
        "operation_id" => operation_id,
        "method" => method,
        "session_id" => session && session.coop_session_id
      })
    end)
  end

  def record_failed_operation(_claim, _run_id, _phase, _operation),
    do: {:error, :improvement_absence_unconfirmed}

  @doc """
  Closes a run none of whose turns can still be running, on local proof
  alone: a turn is sent only inside the run's execution window and no Coop
  turn outlives a day, so the database clock decides. Whatever session the
  worker kept belongs to cleanup.
  """
  def record_expired_stop(claim, run_id, closed_after_seconds)
      when is_integer(closed_after_seconds) and closed_after_seconds > 0 do
    run_transaction(claim, run_id, fn run ->
      unless not is_nil(run.started_at) and
               DateTime.diff(Repo.now!(), run.started_at) >= closed_after_seconds,
             do: Repo.rollback(:improvement_remote_unresolved)

      run =
        if run.status in [:prepared, :responded],
          do:
            run
            |> Ecto.Changeset.change(status: :rejected, error_code: "improvement_attempt_expired")
            |> Repo.update!(),
          else: run

      session = FleetSession.for_run(run)

      store_stop(run, %{
        "kind" => "attempt_expired",
        "closed_after_seconds" => closed_after_seconds,
        "session_id" => session && session.coop_session_id,
        "turn_id" => run.coop_turn_id
      })
    end)
  end

  defp store_stop(run, receipt) do
    receipt = Map.reject(receipt, fn {_key, value} -> is_nil(value) end)

    unless CanonicalJSON.validate(receipt, max_bytes: 4_096) == :ok,
      do: Repo.rollback(:improvement_stop_receipt_invalid)

    cond do
      run.stop_receipt == receipt ->
        run

      not is_nil(run.stop_receipt) ->
        Repo.rollback(:improvement_stop_conflict)

      true ->
        run
        |> Ecto.Changeset.change(stop_receipt: receipt, remote_stopped_at: Repo.now!())
        |> Repo.update!()
    end
  end

  # -- Ownership --------------------------------------------------------------------

  defp run_transaction(claim, run_id, callback) do
    Repo.transaction(fn ->
      candidate = owned!(claim)
      run = locked_run!(candidate, run_id)
      result = callback.(run)
      Improvement.broadcast_improvement_updated(candidate.id)
      result
    end)
  end

  defp locked_run!(candidate, run_id) do
    Repo.one(
      from(run in AnalysisRun,
        where: run.id == ^run_id and run.candidate_id == ^candidate.id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:improvement_run_mismatch)
  end

  defp owned_session?(run, remote_id) do
    Reference.valid?(remote_id, 1_024) and
      Repo.exists?(
        from(session in Session,
          where:
            session.execution_kind == :improvement and session.improvement_run_id == ^run.id and
              session.coop_session_id == ^remote_id
        )
      )
  end

  defp owned!(claim) do
    candidate =
      Repo.one(
        from(candidate in Candidate,
          where: candidate.id == ^claim.candidate.id,
          lock: "FOR UPDATE"
        )
      )

    unless candidate && candidate.analysis == :running && candidate.lease_ref == claim.lease_ref &&
             DateTime.compare(candidate.lease_expires_at, Repo.now!()) == :gt,
           do: Repo.rollback(:improvement_lease_lost)

    candidate
  end

  @doc false
  def lock_owned_in_transaction!(claim), do: owned!(claim)

  defp save(candidate, changes) do
    candidate
    |> Ecto.Changeset.change(changes)
    |> Repo.update!()
    |> tap(&Improvement.broadcast_improvement_updated(&1.id))
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
