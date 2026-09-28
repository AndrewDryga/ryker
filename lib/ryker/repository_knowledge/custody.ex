defmodule Ryker.RepositoryKnowledge.Custody do
  @moduledoc """
  The queue of repositories whose RYKER.md is due for a step, and the custody
  of each model turn that reads one, after the self-analysis pattern
  (`Ryker.Improvement.Analyses`).

  A worker leases an entry for one step: the daily check, a model turn (or the
  outline when no model could finish), or proposing the written document.
  Each model attempt is a run with a frozen prompt, and starting one spends
  one of the write's starts (`start_limit`), so a model that keeps failing
  costs a bounded number of calls. A run whose worker session may still be
  busy is resumed, never replaced: a new run starts only once the last one has
  stop proof. Someone asking for a write (`request_write/3`) needs no lease:
  a step that finishes after it leaves the write it asked for in place.

  Every change a page shows is announced after the outermost commit
  (`Ryker.RepositoryKnowledge.subscribe/0`); a lease renewal is not.
  """

  import Ecto.Query

  alias Ryker.CanonicalJSON
  alias Ryker.Reference
  alias Ryker.Repo
  alias Ryker.RepositoryKnowledge
  alias Ryker.RepositoryKnowledge.{Entry, FleetSession, Run}
  alias Ryker.UTCDateTime
  alias Ryker.Work.Session

  @terminal ~w(completed failed cancelled interrupted budget_exhausted)
  @day_seconds 86_400

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
      Repo.all(
        from(entry in Entry, where: entry.repository_ref in ^refs, select: entry.repository_ref)
      )

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
  repositories in `refs` are checked, written or proposed; a run already out
  at Coop is followed to its stop whatever became of its repository.
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

  defp next_entry(now, refs) do
    Repo.one(
      from(entry in Entry,
        as: :entry,
        where: ^claimable(now, refs),
        order_by: [
          asc: coalesce(entry.next_attempt_at, entry.next_check_at),
          asc: entry.repository_ref
        ],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"
      )
    )
  end

  # A worker stopped renewing its lease; or, unleased, a write or proposal is
  # due for a repository still set up, or has a run out at Coop; or the
  # daily check is due for a repository still set up.
  defp claimable(now, refs) do
    dynamic(
      [entry: e],
      (not is_nil(e.lease_ref) and e.lease_expires_at <= ^now) or
        (is_nil(e.lease_ref) and (^step_due(now, refs) or ^check_due(now, refs)))
    )
  end

  defp step_due(now, refs) do
    dynamic(
      [entry: e],
      e.phase in [:write, :publish] and
        (is_nil(e.next_attempt_at) or e.next_attempt_at <= ^now) and
        (e.repository_ref in ^refs or exists(outstanding_parent_run()))
    )
  end

  defp check_due(now, refs) do
    dynamic(
      [entry: e],
      e.phase == :idle and (is_nil(e.next_check_at) or e.next_check_at <= ^now) and
        e.repository_ref in ^refs
    )
  end

  defp outstanding_parent_run do
    from(run in Run,
      where:
        run.repository_ref == parent_as(:entry).repository_ref and not is_nil(run.started_at) and
          is_nil(run.remote_stopped_at)
    )
  end

  @doc """
  The earliest moment after `since` at which an entry becomes due by the
  clock alone: its check, its retry or hold, or the lease of a worker that
  stopped renewing it. Nil when nothing waits on the clock; a request, a
  setup and a repository added are announced.
  """
  @spec next_due_at(DateTime.t(), [String.t()]) :: DateTime.t() | nil
  def next_due_at(%DateTime{} = since, refs) do
    [attempt_due, check_due, lease_due] =
      Repo.one(
        from(entry in Entry,
          as: :entry,
          select: [
            filter(
              min(entry.next_attempt_at),
              is_nil(entry.lease_ref) and entry.phase in [:write, :publish] and
                entry.next_attempt_at > ^since and
                (entry.repository_ref in ^refs or exists(outstanding_parent_run()))
            ),
            filter(
              min(entry.next_check_at),
              is_nil(entry.lease_ref) and entry.phase == :idle and entry.next_check_at > ^since and
                entry.repository_ref in ^refs
            ),
            filter(
              min(entry.lease_expires_at),
              not is_nil(entry.lease_ref) and entry.lease_expires_at > ^since
            )
          ]
        )
      )

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
  def with_lease(claim, callback) do
    Repo.transaction(fn ->
      _entry = owned!(claim)

      case callback.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "The entry as it is stored now, under the claim's lease."
  def owned(claim), do: Repo.transaction(fn -> owned!(claim) end)

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
  Records what the daily check decided, and gives the lease back:
  `{:write, reason}` has a model read the repository now; `:publish`
  proposes the document Ryker wrote but could not propose before;
  `:current` waits for tomorrow's check; `{:failed, reason}` waits for it
  too and says why. `pull_request_state` is where Ryker's pull request stood,
  when it has one. A write someone asked for while the check ran stays.
  """
  def checked(claim, decision, pull_request_state \\ nil) do
    Repo.transaction(fn ->
      entry = owned!(claim)
      now = Repo.now!()

      state =
        if pull_request_state && entry.pull_request_url,
          do: [pull_request_state: pull_request_state],
          else: []

      changes = if entry.phase == :idle, do: decided(decision, now), else: []

      save(entry, unleased() ++ [checked_at: now] ++ state ++ changes)
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

  defp decided(:publish, now), do: [phase: :publish, next_attempt_at: now]

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
  model is reading the repository already. No lease is taken: a check or a
  proposal that finishes after this leaves the write in place.
  """
  @spec request_write(String.t(), String.t(), String.t() | nil) ::
          {:ok, :requested | :already_writing} | {:error, term()}
  def request_write(ref, reason, actor) do
    Repo.transaction(fn ->
      now = Repo.now!()
      :ok = ensure([ref])

      entry =
        Repo.one!(from(entry in Entry, where: entry.repository_ref == ^ref, lock: "FOR UPDATE"))

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
        Repo.one!(from(entry in Entry, where: entry.repository_ref == ^ref, lock: "FOR UPDATE"))

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
  Ends a write that will not finish: its starts are spent and the RYKER.md
  there is kept (a model wrote Ryker's last one, or the default branch holds
  one a model or a person wrote), or GitHub or the repository refused it for
  a reason another try would meet again. Whatever document the entry holds
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
  Keeps the outline as the document to propose, when no model could finish
  reading a repository that has no RYKER.md a model wrote. It says it is an
  outline, and the next check writes it again.
  """
  def store_outline(claim, document, commit, reason) when is_binary(document) do
    Repo.transaction(fn ->
      entry = owned!(claim)
      now = Repo.now!()

      save(
        entry,
        unleased() ++
          document_fields(document, commit, :outline, nil, nil, now) ++
          [
            phase: :publish,
            start_count: 0,
            next_attempt_at: now,
            error_code: code(reason),
            error: RepositoryKnowledge.outline_failure(reason)
          ]
      )
    end)
  end

  @doc """
  Records that the written document reached GitHub (`result` from
  `Ryker.RepositoryKnowledge.Remote.publish/3`), and gives the lease back:
  the next check comes tomorrow. `settings_write` saves Work's copy of it in
  the same transaction. A write someone asked for while it was proposed
  stays.
  """
  def published(claim, result, settings_write) do
    Repo.transaction(fn ->
      entry = owned!(claim)
      now = Repo.now!()

      pull_request =
        if result.outcome in [:opened, :updated],
          do: [
            pull_request_url: result.url,
            pull_request_number: result.number,
            pull_request_state: :open
          ],
          else: []

      settle =
        if entry.phase == :publish,
          do: [
            phase: :idle,
            start_count: 0,
            next_attempt_at: nil,
            next_check_at: DateTime.add(now, @day_seconds)
          ],
          else: []

      # An outline keeps saying why no model could finish.
      error = if entry.document_by == :outline, do: [], else: [error_code: nil, error: nil]

      entry =
        save(
          entry,
          unleased() ++
            [published_at: now, publication: result.outcome] ++ error ++ pull_request ++ settle
        )

      case settings_write.(entry) do
        :ok -> entry
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  A proposal GitHub refused for a reason another try would meet again: the
  document stays, unproposed, the next check tries again tomorrow, and the
  entry says why.
  """
  def publication_failed(claim, reason) do
    Repo.transaction(fn ->
      entry = owned!(claim)
      now = Repo.now!()

      settle =
        if entry.phase == :publish,
          do: [phase: :idle, next_attempt_at: nil, next_check_at: DateTime.add(now, @day_seconds)],
          else: []

      save(
        entry,
        unleased() ++
          [error_code: code(reason), error: RepositoryKnowledge.failure(reason)] ++ settle
      )
    end)
  end

  defp code({:github_onboarding, kind}), do: "github_#{kind}"
  defp code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp code(_reason), do: "repository_knowledge_failed"

  # -- Runs -------------------------------------------------------------------------

  @doc "The run of a repository that started and has no stop proof yet, or nil."
  def outstanding(ref),
    do:
      Repo.one(
        from(run in Run,
          where:
            run.repository_ref == ^ref and not is_nil(run.started_at) and
              is_nil(run.remote_stopped_at),
          order_by: [asc: run.generation],
          limit: 1
        )
      )

  @doc "A run as it is stored now."
  def current(run_id), do: Repo.get!(Run, run_id)

  @doc "A repository's latest run, or nil."
  def last_run(ref),
    do:
      Repo.one(
        from(run in Run,
          where: run.repository_ref == ^ref,
          order_by: [desc: run.generation],
          limit: 1
        )
      )

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

      Repo.update_all(
        from(run in Run,
          where:
            run.repository_ref == ^entry.repository_ref and run.status == :prepared and
              is_nil(run.started_at)
        ),
        set: [
          status: :stale,
          error_code: "repository_knowledge_attempt_replaced",
          updated_at: Repo.now!()
        ]
      )

      {:ok,
       Repo.insert!(%Run{
         id: Ecto.UUID.generate(),
         repository_ref: entry.repository_ref,
         generation: next_generation(entry.repository_ref),
         status: :prepared,
         source_commit: attempt.commit,
         policy: attempt.policy,
         policy_digest: attempt.policy_digest,
         transport: attempt.transport,
         conversation_ref: attempt.conversation_ref,
         prompt: attempt.prompt,
         prompt_sha256: sha256(attempt.prompt),
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
    Repo.one(
      from(run in Run,
        where: run.repository_ref == ^ref,
        order_by: [desc: run.generation],
        limit: 1,
        select: run.error_code
      )
    ) in ~w(output_contract_failed invalid_repository_knowledge repository_knowledge_unusable)
  end

  defp next_generation(ref),
    do:
      (Repo.one(from(run in Run, where: run.repository_ref == ^ref, select: max(run.generation))) ||
         0) + 1

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
  def operation_key(%Run{id: id}, phase) when phase in [:create, :submit, :cancel],
    do: "ryker:knowledge:#{phase}:#{id}"

  @doc "Freezes the session revision the turn is submitted at, before it is sent."
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

    if sha256(result) == digest and CanonicalJSON.validate(producer, max_bytes: 4_096) == :ok,
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
        run
        |> Ecto.Changeset.change(Map.merge(answer, %{status: :responded, document: nil}))
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
  Makes the run's checked document the one to propose: the run is applied
  with its turn's stop proof, and the entry holds the document, from the
  commit the run read, ready to publish. Both in one transaction, so a step
  that ends before it leaves the run outstanding and the next one reads the
  same finished turn instead of asking the model again.
  """
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
        |> store_stop(terminal_receipt(turn))

      now = Repo.now!()

      save(
        entry,
        document_fields(run.document, run.source_commit, :model, run.id, run.dropped_count, now) ++
          [phase: :publish, next_attempt_at: now, error_code: nil, error: nil]
      )
    end)
  end

  def apply_result(_claim, _run_id, _turn), do: {:error, :repository_knowledge_remote_not_stopped}

  defp document_fields(document, commit, by, run_id, dropped, now),
    do: [
      document: document,
      document_sha256: sha256(document),
      document_commit: commit,
      document_by: by,
      document_run_id: run_id,
      dropped_count: dropped,
      document_at: now,
      published_at: nil,
      publication: nil
    ]

  @doc "Ends an attempt that cannot write the document, without mistaking it for one that did."
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
        do: Repo.rollback(:repository_knowledge_remote_identity_conflict)

      store_stop(run, terminal_receipt(turn))
    end)
  end

  def record_stop(_claim, _run_id, _turn), do: {:error, :repository_knowledge_remote_not_stopped}

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
      when reason in [:output_contract_failed, :repository_knowledge_provider_failed] and
             state in @terminal do
    run_transaction(claim, run_id, fn run ->
      unless run.coop_turn_id == turn_id and owned_session?(run, turn["session_id"]),
        do: Repo.rollback(:repository_knowledge_remote_identity_conflict)

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
  def record_unaddressable_stop(claim, run_id, reason) when is_binary(reason) do
    run_transaction(claim, run_id, fn run ->
      unless run.status in [:stale, :rejected] and is_nil(run.submit_revision) and
               is_nil(run.coop_turn_id),
             do: Repo.rollback(:repository_knowledge_absence_unconfirmed)

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
             do: Repo.rollback(:repository_knowledge_absence_unconfirmed)

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
             do: Repo.rollback(:repository_knowledge_absence_unconfirmed)

      run =
        if run.status in [:prepared, :responded],
          do:
            run
            |> Ecto.Changeset.change(
              status: :rejected,
              error_code: "repository_knowledge_provider_failed"
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
    do: {:error, :repository_knowledge_absence_unconfirmed}

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
             do: Repo.rollback(:repository_knowledge_remote_unresolved)

      run =
        if run.status in [:prepared, :responded],
          do:
            run
            |> Ecto.Changeset.change(
              status: :rejected,
              error_code: "repository_knowledge_attempt_expired"
            )
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
    Repo.one(
      from(run in Run,
        where: run.id == ^run_id and run.repository_ref == ^entry.repository_ref,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:repository_knowledge_run_mismatch)
  end

  defp owned_session?(run, remote_id) do
    Reference.valid?(remote_id, 1_024) and
      Repo.exists?(
        from(session in Session,
          where:
            session.execution_kind == :knowledge and session.knowledge_run_id == ^run.id and
              session.coop_session_id == ^remote_id
        )
      )
  end

  defp owned!(claim) do
    entry =
      Repo.one(
        from(entry in Entry,
          where: entry.repository_ref == ^claim.entry.repository_ref,
          lock: "FOR UPDATE"
        )
      )

    unless entry && entry.lease_ref == claim.lease_ref &&
             DateTime.compare(entry.lease_expires_at, Repo.now!()) == :gt,
           do: Repo.rollback(:repository_knowledge_lease_lost)

    entry
  end

  @doc false
  def lock_owned_in_transaction!(claim), do: owned!(claim)

  defp unleased, do: [lease_ref: nil, lease_owner: nil, lease_expires_at: nil]

  defp save(entry, changes) do
    entry
    |> Ecto.Changeset.change(changes)
    |> Repo.update!()
    |> tap(&RepositoryKnowledge.broadcast_updated(&1.repository_ref))
  end

  defp bounded(text, maximum) do
    text = String.trim(text)
    if String.length(text) <= maximum, do: text, else: String.slice(text, 0, maximum - 1) <> "…"
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
