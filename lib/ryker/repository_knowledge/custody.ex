defmodule Ryker.RepositoryKnowledge.Custody do
  @moduledoc """
  The queue of repositories whose RYKER.md is due for a step, and the custody
  of each model turn that reads one, after the self-analysis pattern
  (`Ryker.Improvement.Analyses`).

  A worker leases an entry for one step: the daily check, or a model turn (or
  the outline when no model could finish). A written document is the
  repository's knowledge at once; nothing is written to the repository.
  Each model attempt is a run with a frozen prompt, and starting one spends
  one of the write's starts (`start_limit`), so a model that keeps failing
  costs a bounded number of calls. A run whose worker session may still be
  busy is resumed, never replaced: a new run starts only once the last one has
  stop proof. Someone asking for a write (`request_write/3`) needs no lease:
  a step that finishes after it leaves the write it asked for in place.

  Every change a page shows is announced after the outermost commit
  (`Ryker.RepositoryKnowledge.subscribe/0`); a lease renewal is not.
  """
  @behaviour Ryker.Coop.RunStep.Store
  alias Ryker.CanonicalJSON
  alias Ryker.Coop
  alias Ryker.Crypto
  alias Ryker.Lease
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.RepositoryKnowledge
  alias Ryker.RepositoryKnowledge.{Entry, FleetSession, Run}
  alias Ryker.Text
  alias Ryker.UTCDateTime
  alias Ryker.Work
  require Logger

  @terminal ~w(completed failed cancelled interrupted budget_exhausted)
  @day_seconds 86_400
  @held_codes ~w(repository_knowledge_policy_unavailable repository_knowledge_worker_unavailable
                 repository_knowledge_github_unavailable)

  @type claim :: %{entry: Entry.t(), lease_ref: Ecto.UUID.t()}

  # -- The queue --------------------------------------------------------------------

  @doc """
  Makes sure every repository in `refs` has an entry: one added before this
  lane existed, or whose setup could not ask for its first check, is checked
  at once.
  """
  @spec ensure([String.t()]) :: :ok
  def ensure([]), do: :ok

  def ensure(refs) when is_list(refs) do
    known =
      refs |> Entry.Query.by_repositories() |> Entry.Query.select_refs() |> Repo.all()

    case refs -- known do
      [] ->
        :ok

      missing ->
        now = Repo.now!()

        Repo.insert_all(
          Entry,
          Enum.map(missing, fn ref ->
            %{
              repository_ref: ref,
              phase: :idle,
              next_check_at: now,
              inserted_at: now,
              updated_at: now
            }
          end),
          on_conflict: :nothing,
          conflict_target: :repository_ref
        )

        :ok
    end
  end

  @doc """
  Leases the next entry due for a step, or one whose worker stopped renewing
  its lease: `{:ok, claim}`, or `{:ok, :idle}` with nothing to do. Only the
  repositories in `refs` are checked or written; a run already out at Coop
  is followed to its stop whatever became of its repository.
  """
  @spec claim(String.t(), map(), [String.t()]) :: {:ok, claim() | :idle} | {:error, term()}
  def claim(worker, settings, refs) do
    Repo.transaction(fn ->
      now = Repo.now!()

      case next_entry(now, refs) do
        nil -> :idle
        entry -> lease(entry, worker, settings.lease_seconds, now)
      end
    end)
  end

  defp next_entry(now, refs), do: now |> Entry.Query.next_claimable(refs) |> Repo.peek()

  @doc """
  The earliest moment after `since` at which an entry becomes due by the
  clock alone: its check, its retry or hold, or the lease of a worker that
  stopped renewing it. Nil when nothing waits on the clock; a request, a
  setup and a repository added are announced.
  """
  @spec next_due_at(DateTime.t(), [String.t()]) :: DateTime.t() | nil
  def next_due_at(%DateTime{} = since, refs) do
    [attempt_due, check_due, lease_due] =
      since |> Entry.Query.select_next_due_after(refs) |> Repo.one()

    UTCDateTime.earliest([attempt_due, check_due, lease_due])
  end

  defp lease(entry, worker, seconds, now) do
    entry =
      save(entry,
        lease_ref: Ecto.UUID.generate(),
        lease_owner: worker,
        heartbeat_at: now,
        lease_expires_at: DateTime.add(now, seconds, :second)
      )

    %{entry: entry, lease_ref: entry.lease_ref}
  end

  @doc "Extends the lease; nothing a page shows changes."
  @impl true
  def renew(claim, seconds) do
    Repo.transaction(fn ->
      now = Repo.now!()

      claim
      |> owned!()
      |> Ecto.Changeset.change(heartbeat_at: now, lease_expires_at: DateTime.add(now, seconds))
      |> Repo.update!()
    end)
  end

  @doc "Fences local state changes with the lease. Never call GitHub or Coop inside `callback`."
  @impl true
  def with_lease(claim, callback) do
    Repo.transaction(fn ->
      _entry = owned!(claim)

      case callback.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Gives the lease back and asks to be claimed again after `delay_seconds`:
  the step waits, whatever it was, and nothing else changes.
  """
  def yield(claim, delay_seconds) when is_integer(delay_seconds) and delay_seconds >= 0 do
    Repo.transaction(fn ->
      entry = owned!(claim)
      at = DateTime.add(Repo.now!(), delay_seconds)

      due =
        if entry.phase == :idle, do: [next_check_at: at], else: [next_attempt_at: at]

      save(entry, unleased() ++ due)
    end)
  end

  @doc """
  Gives the lease back because the step cannot go on yet, and says why on the
  entry: no policy reads the repository, no worker takes its sessions, or
  GitHub did not answer. Holding this way said nothing anywhere, and a write
  could wait a minute at a time for good (2026-10-04 review). A new cause is
  logged once; the same cause again waits `repeat_delay_seconds`.
  """
  def hold(claim, code, delay_seconds, repeat_delay_seconds)
      when is_binary(code) and is_integer(delay_seconds) and delay_seconds >= 0 and
             is_integer(repeat_delay_seconds) and repeat_delay_seconds >= delay_seconds do
    Repo.transaction(fn ->
      entry = owned!(claim)
      repeated = entry.error_code == code
      at = DateTime.add(Repo.now!(), if(repeated, do: repeat_delay_seconds, else: delay_seconds))
      due = if entry.phase == :idle, do: [next_check_at: at], else: [next_attempt_at: at]

      unless repeated do
        Logger.warning("repository knowledge for #{entry.repository_ref} waits: #{held(code)}")
      end

      save(entry, unleased() ++ due ++ [error_code: code, error: held(code)])
    end)
  end

  defp held("repository_knowledge_policy_unavailable"),
    do: "No model setup reads this repository yet. Ryker waits until it can read it on GitHub."

  defp held("repository_knowledge_worker_unavailable"),
    do: "No Coop worker takes this repository's sessions. Check that a worker is online."

  defp held("repository_knowledge_github_unavailable"),
    do: "GitHub did not answer for this repository. Ryker tries again."

  @doc """
  Records what the daily check decided, and gives the lease back:
  `{:write, reason}` has a model read the repository now; `:current` waits
  for tomorrow's check; `{:failed, reason}` waits for it too and says why. A
  write someone asked for while the check ran stays.
  """
  def checked(claim, decision) do
    Repo.transaction(fn ->
      entry = owned!(claim)
      now = Repo.now!()
      changes = if entry.phase == :idle, do: decided(decision, now), else: []

      save(entry, unleased() ++ [checked_at: now] ++ changes)
    end)
  end

  defp decided({:write, reason}, now),
    do: [
      phase: :write,
      reason: bounded(reason, 512),
      requested_by: nil,
      start_count: 0,
      next_attempt_at: now
    ]

  defp decided(:current, now),
    do: [next_check_at: DateTime.add(now, @day_seconds), error_code: nil, error: nil]

  defp decided({:failed, reason}, now),
    do: [
      next_check_at: DateTime.add(now, @day_seconds),
      error_code: code(reason),
      error: RepositoryKnowledge.failure(reason)
    ]

  @doc """
  Asks for RYKER.md to be written now, as the Repositories page's Refresh
  knowledge does: `{:ok, :requested}`, or `{:ok, :already_writing}` while a
  model is reading the repository already. No lease is taken: a check that
  finishes after this leaves the write in place.
  """
  @spec request_write(String.t(), String.t(), String.t() | nil) ::
          {:ok, :requested | :already_writing} | {:error, term()}
  def request_write(ref, reason, actor) do
    Repo.transaction(fn ->
      now = Repo.now!()
      :ok = ensure([ref])

      entry =
        ref |> Entry.Query.by_repository() |> Entry.Query.lock_for_update() |> Repo.one!()

      if entry.phase == :write do
        :already_writing
      else
        save(entry,
          phase: :write,
          reason: bounded(reason, 512),
          requested_by: actor && bounded(actor, 256),
          start_count: 0,
          next_attempt_at: now
        )

        :requested
      end
    end)
  end

  @doc "Asks for the daily check now, as a repository that was just set up does."
  @spec check_now(String.t()) :: :ok
  def check_now(ref) do
    Repo.transaction(fn ->
      :ok = ensure([ref])

      entry =
        ref |> Entry.Query.by_repository() |> Entry.Query.lock_for_update() |> Repo.one!()

      if entry.phase == :idle, do: save(entry, next_check_at: Repo.now!())
    end)

    :ok
  end

  @doc """
  Ends a model attempt that wrote nothing, once nothing of it can still be
  running: the write waits `delay_seconds` for its next start, and says why
  the last one failed.
  """
  def release(claim, reason, delay_seconds) when is_atom(reason) and delay_seconds >= 0 do
    Repo.transaction(fn ->
      entry = owned!(claim)

      save(
        entry,
        unleased() ++
          [
            next_attempt_at: DateTime.add(Repo.now!(), delay_seconds),
            error_code: code(reason),
            error: RepositoryKnowledge.failure(reason)
          ]
      )
    end)
  end

  @doc """
  Ends a write that will not finish: its starts are spent and the RYKER.md a
  model wrote last is kept, or GitHub or the repository refused it for a
  reason another try would meet again. Whatever document the entry holds
  stays as it is, the next check comes tomorrow, and the entry says why.
  """
  def give_up_write(claim, reason) do
    Repo.transaction(fn ->
      entry = owned!(claim)
      now = Repo.now!()

      save(
        entry,
        unleased() ++
          [
            phase: :idle,
            start_count: 0,
            next_attempt_at: nil,
            next_check_at: DateTime.add(now, @day_seconds),
            error_code: code(reason),
            error: RepositoryKnowledge.failure(reason)
          ]
      )
    end)
  end

  @doc """
  Keeps the outline as the repository's knowledge, when no model could finish
  reading a repository no model ever wrote a RYKER.md for, and gives the
  lease back. It says it is an outline, and tomorrow's check writes it again.
  """
  def store_outline(claim, document, commit, reason) when is_binary(document) do
    Repo.transaction(fn ->
      entry = owned!(claim)
      now = Repo.now!()

      save(
        entry,
        unleased() ++
          document_fields(document, commit, :outline, nil, nil, now) ++
          settled(now) ++
          [error_code: code(reason), error: RepositoryKnowledge.outline_failure(reason)]
      )
    end)
  end

  # A document is written: nothing is due until tomorrow's check.
  defp settled(now),
    do: [
      phase: :idle,
      start_count: 0,
      next_attempt_at: nil,
      next_check_at: DateTime.add(now, @day_seconds)
    ]

  defp code({:github_onboarding, kind}), do: "github_#{kind}"
  defp code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp code(_reason), do: "repository_knowledge_failed"

  # -- Runs -------------------------------------------------------------------------

  @doc "The run of a repository that started and has no stop proof yet."
  @spec fetch_outstanding(String.t()) :: {:ok, Run.t()} | {:error, :not_found}
  def fetch_outstanding(ref) do
    ref
    |> Run.Query.by_repository()
    |> Run.Query.outstanding()
    |> Run.Query.ordered_by_generation()
    |> Run.Query.limit_to(1)
    |> Repo.fetch()
  end

  @doc "A run as it is stored now."
  @impl true
  def current(run_id), do: Repo.one!(Run.Query.by_id(run_id))

  @doc "A repository's latest run."
  @spec fetch_last_run(String.t()) :: {:ok, Run.t()} | {:error, :not_found}
  def fetch_last_run(ref) do
    ref
    |> Run.Query.by_repository()
    |> Run.Query.ordered_by_generation_desc()
    |> Run.Query.limit_to(1)
    |> Repo.fetch()
  end

  @doc """
  Freezes the next attempt: the prompt and schema the turn will get, the
  commit it reads, and the policy it runs under. An attempt prepared earlier
  that never started goes stale; nothing of it was sent.
  """
  @spec prepare(claim(), map()) :: {:ok, Run.t()} | {:error, term()}
  def prepare(claim, attempt) do
    with_lease(claim, fn ->
      entry = owned!(claim)

      if entry.start_count >= entry.start_limit,
        do: Repo.rollback(:repository_knowledge_retry_exhausted)

      # A write that starts is no longer held.
      if entry.error_code in @held_codes, do: save(entry, error_code: nil, error: nil)

      entry.repository_ref
      |> Run.Query.by_repository()
      |> Run.Query.prepared_unstarted()
      |> Repo.update_all(
        set: [
          status: :stale,
          error_code: "repository_knowledge_attempt_replaced",
          updated_at: Repo.now!()
        ]
      )

      {:ok,
       Repo.insert!(%Run{
         repository_ref: entry.repository_ref,
         generation: next_generation(entry.repository_ref),
         status: :prepared,
         source_commit: attempt.commit,
         policy: attempt.policy,
         policy_digest: attempt.policy_digest,
         transport: attempt.transport,
         conversation_ref: attempt.conversation_ref,
         prompt: attempt.prompt,
         prompt_sha256: Crypto.sha256_hex(attempt.prompt),
         output_schema: attempt.output_schema,
         manifest: attempt.manifest
       })}
    end)
  end

  @doc """
  Whether the last attempt of the write under way failed its contract or
  named nothing the repository holds, so the next prompt says so.
  """
  def retry?(%Entry{start_count: 0}), do: false

  def retry?(%Entry{repository_ref: ref}) do
    last_error =
      ref
      |> Run.Query.by_repository()
      |> Run.Query.ordered_by_generation_desc()
      |> Run.Query.limit_to(1)
      |> Run.Query.select_error_codes()
      |> Repo.one()

    last_error in ~w(output_contract_failed invalid_repository_knowledge repository_knowledge_unusable)
  end

  defp next_generation(ref) do
    latest =
      ref |> Run.Query.by_repository() |> Run.Query.select_latest_generation() |> Repo.one()

    (latest || 0) + 1
  end

  @doc "Spends one start on the run, once, when it first begins; retries of it do not spend again."
  def begin_execution(claim, run_id) do
    Repo.transaction(fn ->
      entry = owned!(claim)
      run = locked_run!(entry, run_id)

      cond do
        not is_nil(run.started_at) ->
          run

        run.status != :prepared ->
          Repo.rollback(:repository_knowledge_run_mismatch)

        entry.start_count >= entry.start_limit ->
          Repo.rollback(:repository_knowledge_retry_exhausted)

        true ->
          save(entry, start_count: entry.start_count + 1)
          run |> Ecto.Changeset.change(started_at: Repo.now!()) |> Repo.update!()
      end
    end)
  end

  @doc "Counts one more failure to learn how a run ended at the worker."
  def reconciliation_failed(claim, run_id) do
    with_lease(claim, fn ->
      run = locked_run!(claim.entry, run_id)

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
  @impl true
  def operation_key(%Run{id: id}, phase) when phase in [:create, :submit, :cancel],
    do: "ryker:knowledge:#{phase}:#{id}"

  @doc "Freezes the session revision the turn is submitted at, before it is sent."
  @impl true
  def freeze_submit(claim, run_id, revision) when is_integer(revision) and revision > 0 do
    run_transaction(claim, run_id, fn run ->
      cond do
        run.submit_revision == revision ->
          run

        not is_nil(run.submit_revision) ->
          Repo.rollback(:repository_knowledge_submission_conflict)

        run.status != :prepared or is_nil(run.started_at) or not is_nil(run.remote_stopped_at) ->
          Repo.rollback(:repository_knowledge_attempt_not_running)

        true ->
          run |> Ecto.Changeset.change(submit_revision: revision) |> Repo.update!()
      end
    end)
  end

  def freeze_submit(_claim, _run_id, _revision),
    do: {:error, :invalid_repository_knowledge_revision}

  @doc "Binds the run to the Coop turn its submission became, once."
  @impl true
  def bind_turn(claim, run_id, session_id, turn_id) do
    run_transaction(claim, run_id, fn run ->
      unless owned_session?(run, session_id) and Reference.valid?(turn_id, 1_024),
        do: Repo.rollback(:repository_knowledge_remote_identity_conflict)

      case run.coop_turn_id do
        nil -> run |> Ecto.Changeset.change(coop_turn_id: turn_id) |> Repo.update!()
        ^turn_id -> run
        _other -> Repo.rollback(:repository_knowledge_remote_identity_conflict)
      end
    end)
  end

  @doc "Stores the exact answer the turn offered, before anything is checked, acknowledged or applied."
  @impl true
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
      when is_binary(result) and byte_size(result) <= 131_072 and is_integer(attempt) and
             attempt > 0 do
    answer = %{
      result: result,
      result_sha256: digest,
      producer: producer,
      candidate_attempt: attempt
    }

    if Crypto.sha256_hex(result) == digest and
         CanonicalJSON.validate(producer, max_bytes: 4_096) == :ok,
       do: run_transaction(claim, run_id, &save_candidate(&1, turn_id, session_id, answer)),
       else: {:error, :invalid_repository_knowledge_candidate}
  end

  def record_candidate(_claim, _run_id, _turn, _producer),
    do: {:error, :invalid_repository_knowledge}

  defp save_candidate(run, turn_id, session_id, answer) do
    unless run.coop_turn_id == turn_id and owned_session?(run, session_id),
      do: Repo.rollback(:repository_knowledge_remote_identity_conflict)

    cond do
      run.result == answer.result and run.candidate_attempt == answer.candidate_attempt ->
        run

      run.status in [:prepared, :responded] ->
        changes = Map.merge(answer, %{status: :responded, document: nil})

        run
        |> Ecto.Changeset.change(changes)
        |> Repo.update!()

      true ->
        Repo.rollback(:repository_knowledge_attempt_finished)
    end
  end

  @doc """
  Keeps the document the host wrote from the run's answer once every path
  and command in it was checked against the repository, before Coop is told
  to accept the answer. A step repeated after a crash reads it instead of
  checking again.
  """
  def record_document(claim, run_id, document, dropped)
      when is_binary(document) and is_integer(dropped) and dropped >= 0 do
    run_transaction(claim, run_id, fn run ->
      cond do
        run.status != :responded ->
          Repo.rollback(:repository_knowledge_attempt_finished)

        is_binary(run.document) ->
          run

        true ->
          run
          |> Ecto.Changeset.change(document: document, dropped_count: dropped)
          |> Repo.update!()
      end
    end)
  end

  @doc "Keeps the proof that Coop accepted exactly this answer on exactly this turn."
  @impl true
  def confirm_candidate(claim, run_id, turn) do
    run_transaction(claim, run_id, fn run ->
      receipt =
        Map.take(
          turn,
          ~w(id session_id validation_attempt validation_candidate_sha256 validation_receipt)
        )

      cond do
        not accepted?(run, turn) ->
          Repo.rollback(:repository_knowledge_validation_unconfirmed)

        run.validation_receipt == receipt ->
          run

        not is_nil(run.validation_receipt) ->
          Repo.rollback(:repository_knowledge_validation_conflict)

        true ->
          run |> Ecto.Changeset.change(validation_receipt: receipt) |> Repo.update!()
      end
    end)
  end

  defp accepted?(run, turn) do
    turn["state"] == "completed" and turn["id"] == run.coop_turn_id and
      owned_session?(run, turn["session_id"]) and is_binary(run.result) and
      turn["assistant_message"] == run.result and
      turn["validation_attempt"] == run.candidate_attempt and
      turn["validation_candidate_sha256"] == run.result_sha256 and
      Reference.valid?(turn["validation_receipt"], 1_024)
  end

  @doc """
  Makes the run's checked document the repository's knowledge, and gives the
  lease back: the run is applied with its turn's stop proof, and the entry
  holds the document, from the commit the run read, until tomorrow's check.
  Work is briefed with it from then on. Both in one transaction, so a step
  that ends before it leaves the run outstanding and the next one reads the
  same finished turn instead of asking the model again.
  """
  @impl true
  def apply_result(claim, run_id, %{"state" => "completed"} = turn) do
    Repo.transaction(fn ->
      entry = owned!(claim)
      run = locked_run!(entry, run_id)

      unless run.status in [:responded, :applied] and is_binary(run.document) and
               is_map(run.validation_receipt),
             do: Repo.rollback(:repository_knowledge_validation_unconfirmed)

      unless run.coop_turn_id == turn["id"] and owned_session?(run, turn["session_id"]),
        do: Repo.rollback(:repository_knowledge_remote_identity_conflict)

      run =
        run
        |> Ecto.Changeset.change(status: :applied)
        |> Repo.update!()
        |> store_stop(Coop.Documents.terminal_receipt(turn))

      now = Repo.now!()

      save(
        entry,
        unleased() ++
          document_fields(run.document, run.source_commit, :model, run.id, run.dropped_count, now) ++
          settled(now) ++ [error_code: nil, error: nil]
      )
    end)
  end

  def apply_result(_claim, _run_id, _turn), do: {:error, :repository_knowledge_remote_not_stopped}

  defp document_fields(document, commit, by, run_id, dropped, now),
    do: [
      document: document,
      document_sha256: Crypto.sha256_hex(document),
      document_commit: commit,
      document_by: by,
      document_run_id: run_id,
      dropped_count: dropped,
      document_at: now
    ]

  @doc "Ends an attempt that cannot write the document, without mistaking it for one that did."
  @impl true
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
  @impl true
  def record_stop(claim, run_id, %{"state" => state, "id" => turn_id} = turn)
      when state in @terminal do
    run_transaction(claim, run_id, fn run ->
      unless run.coop_turn_id == turn_id and owned_session?(run, turn["session_id"]),
        do: Repo.rollback(:repository_knowledge_remote_identity_conflict)

      store_stop(run, Coop.Documents.terminal_receipt(turn))
    end)
  end

  def record_stop(_claim, _run_id, _turn), do: {:error, :repository_knowledge_remote_not_stopped}

  @doc """
  Records a terminal turn that gave no usable answer: the model's output did
  not match the contract, or the provider failed. The turn is its own stop proof.
  """
  @impl true
  def fail(claim, run_id, reason, %{"state" => state, "id" => turn_id} = turn)
      when reason in [:output_contract_failed, :repository_knowledge_provider_failed] and
             state in @terminal do
    run_transaction(claim, run_id, fn run ->
      unless run.coop_turn_id == turn_id and owned_session?(run, turn["session_id"]),
        do: Repo.rollback(:repository_knowledge_remote_identity_conflict)

      run =
        if run.status in [:prepared, :responded] do
          run
          |> Ecto.Changeset.change(status: :rejected, error_code: Atom.to_string(reason))
          |> Repo.update!()
        else
          run
        end

      store_stop(run, Coop.Documents.failure_receipt(turn))
    end)
  end

  @doc """
  An ended run whose turn was never submitted stops on that proof: its
  session is bound, and Coop has no submit for its key (the caller asked).
  """
  @impl true
  def record_unsubmitted_stop(claim, run_id, session_id) do
    run_transaction(claim, run_id, fn run ->
      unless run.status in [:stale, :rejected] and is_nil(run.coop_turn_id) and
               owned_session?(run, session_id),
             do: Repo.rollback(:repository_knowledge_absence_unconfirmed)

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
  @impl true
  def record_unaddressable_stop(claim, run_id, reason) when is_binary(reason) do
    run_transaction(claim, run_id, fn run ->
      unless run.status in [:stale, :rejected] and is_nil(run.submit_revision) and
               is_nil(run.coop_turn_id),
             do: Repo.rollback(:repository_knowledge_absence_unconfirmed)

      session_id = FleetSession.coop_session_id(run)

      store_stop(run, %{
        "kind" => "never_submitted",
        "reason" => reason,
        "session" => "unaddressable",
        "session_id" => session_id
      })
    end)
  end

  @doc """
  An ended run whose session was never asked for stops on that proof: its
  session is not bound, and Coop has no create for its key (the caller
  asked).
  """
  @impl true
  def record_uncreated_stop(claim, run_id) do
    run_transaction(claim, run_id, fn run ->
      session_id = FleetSession.coop_session_id(run)

      unless run.status in [:stale, :rejected] and is_nil(run.coop_turn_id) and
               is_nil(session_id),
             do: Repo.rollback(:repository_knowledge_absence_unconfirmed)

      store_stop(run, %{"kind" => "never_created"})
    end)
  end

  @doc """
  A create or submit that Coop reports failed started nothing: no session
  or no turn exists for that key, so the run stops on that proof.
  """
  @impl true
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
             do: Repo.rollback(:repository_knowledge_absence_unconfirmed)

      run =
        if run.status in [:prepared, :responded] do
          run
          |> Ecto.Changeset.change(
            status: :rejected,
            error_code: "repository_knowledge_provider_failed"
          )
          |> Repo.update!()
        else
          run
        end

      session_id = FleetSession.coop_session_id(run)

      store_stop(run, %{
        "kind" => "failed_operation",
        "phase" => Atom.to_string(phase),
        "operation_id" => operation_id,
        "method" => method,
        "session_id" => session_id
      })
    end)
  end

  def record_failed_operation(_claim, _run_id, _phase, _operation),
    do: {:error, :repository_knowledge_absence_unconfirmed}

  @doc """
  Closes a run none of whose turns can still be running, on local proof
  alone: a turn is sent only inside the run's execution window and no Coop
  turn outlives a day, so the database clock decides. Whatever session the
  worker kept belongs to cleanup.
  """
  @impl true
  def record_expired_stop(claim, run_id, closed_after_seconds)
      when is_integer(closed_after_seconds) and closed_after_seconds > 0 do
    run_transaction(claim, run_id, fn run ->
      unless not is_nil(run.started_at) and
               DateTime.diff(Repo.now!(), run.started_at) >= closed_after_seconds,
             do: Repo.rollback(:repository_knowledge_remote_unresolved)

      run =
        if run.status in [:prepared, :responded] do
          run
          |> Ecto.Changeset.change(
            status: :rejected,
            error_code: "repository_knowledge_attempt_expired"
          )
          |> Repo.update!()
        else
          run
        end

      session_id = FleetSession.coop_session_id(run)

      store_stop(run, %{
        "kind" => "attempt_expired",
        "closed_after_seconds" => closed_after_seconds,
        "session_id" => session_id,
        "turn_id" => run.coop_turn_id
      })
    end)
  end

  defp store_stop(run, receipt) do
    receipt = Map.reject(receipt, fn {_key, value} -> is_nil(value) end)

    unless CanonicalJSON.validate(receipt, max_bytes: 4_096) == :ok,
      do: Repo.rollback(:repository_knowledge_stop_receipt_invalid)

    cond do
      run.stop_receipt == receipt ->
        run

      not is_nil(run.stop_receipt) ->
        Repo.rollback(:repository_knowledge_stop_conflict)

      true ->
        run
        |> Ecto.Changeset.change(stop_receipt: receipt, remote_stopped_at: Repo.now!())
        |> Repo.update!()
    end
  end

  # -- Ownership --------------------------------------------------------------------

  defp run_transaction(claim, run_id, callback) do
    Repo.transaction(fn ->
      entry = owned!(claim)
      run = locked_run!(entry, run_id)
      result = callback.(run)
      RepositoryKnowledge.broadcast_updated(entry.repository_ref)
      result
    end)
  end

  defp locked_run!(entry, run_id) do
    run =
      run_id
      |> Run.Query.by_id()
      |> Run.Query.by_repository(entry.repository_ref)
      |> Run.Query.lock_for_update()
      |> Repo.peek()

    run || Repo.rollback(:repository_knowledge_run_mismatch)
  end

  defp owned_session?(run, remote_id) do
    Reference.valid?(remote_id, 1_024) and
      run.id
      |> Work.Session.Query.by_knowledge_run_id()
      |> Work.Session.Query.by_coop_session_id(remote_id)
      |> Repo.exists?()
  end

  defp owned!(claim) do
    entry =
      claim.entry.repository_ref
      |> Entry.Query.by_repository()
      |> Entry.Query.lock_for_update()
      |> Repo.peek()

    unless entry && Lease.held?(entry, claim.lease_ref, Repo.now!()),
      do: Repo.rollback(:repository_knowledge_lease_lost)

    entry
  end

  @doc false
  @impl true
  def lock_owned_in_transaction!(claim), do: owned!(claim)

  defp unleased, do: [lease_ref: nil, lease_owner: nil, lease_expires_at: nil]

  defp save(entry, changes) do
    entry
    |> Ecto.Changeset.change(changes)
    |> Repo.update!()
    |> tap(&RepositoryKnowledge.broadcast_updated(&1.repository_ref))
  end

  # Within `maximum` characters as the row's char_length check counts them,
  # code points, ending in "…" when cut. A model's reason in accents typed
  # after their letters counted half as long and failed the check.
  defp bounded(text, maximum) do
    text = String.trim(text)

    if Text.char_length(text) <= maximum,
      do: text,
      else: Text.characters(text, maximum - 1) <> "…"
  end
end
