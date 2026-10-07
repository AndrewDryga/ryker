defmodule Ryker.Learning.Batches do
  @moduledoc """
  Durable, exclusively assigned learning inputs and leased execution budgets.

  A routed message that started Work is learned from once that Work has come
  to rest, and its quiet time and maximum delay count from then; one that
  started none counts them from when it was routed.

  Every batch or pass this module writes is announced after the outermost
  commit (`Ryker.Learning.subscribe_learning/0`), except a lease renewal.
  """
  alias Ryker.{AdvisoryLock, CanonicalJSON}
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Learning
  alias Ryker.Learning.{Batch, InputMembership}
  alias Ryker.Learning.{LearningInput, LearningRun, LearningSources}
  alias Ryker.Learning.{Observations, Rebuilds, Runtime}
  alias Ryker.Repo
  alias Ryker.UTCDateTime

  @doc "The one key a conversation scope owns a queued or running batch under."
  @spec scope_key(map()) :: String.t()
  def scope_key(scope) do
    scope
    |> Map.update!(:execution_mode, &Atom.to_string/1)
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
    |> CanonicalJSON.digest()
  end

  @doc """
  Serializes queue assignment, never model execution, so exclusive
  membership and the single active scope stay one decision.
  """
  @spec lock_queue!() :: :ok
  def lock_queue! do
    unless Repo.in_transaction?(),
      do: raise(ArgumentError, "the learning queue lock requires a transaction")

    AdvisoryLock.hold!("learning-queue")
  end

  def claim(worker, settings) do
    Repo.transaction(fn ->
      now = Repo.now!()
      lock_queue!()
      batch = next_batch(now) || create_batch(settings, now)
      if batch, do: lease(batch, worker, settings.lease_seconds, now), else: :idle
    end)
  end

  @doc """
  The earliest moment after `since` at which learning has something to claim
  by the clock alone: a batch's retry or hold ends, the lease of a batch
  nobody renewed runs out, or a conversation's unlearned messages have been
  quiet for `quiet_seconds`, or waited `maximum_delay_seconds`, counted from
  when each was routed or its Work came to rest. Nil when nothing waits on
  the clock.

  Everything else that gives learning work (a message routed, Work coming to
  rest, a batch finished or retried) is announced.
  """
  @spec next_due_at(DateTime.t(), map()) :: DateTime.t() | nil
  def next_due_at(%DateTime{} = since, settings) do
    batches = Repo.one(Batch.Query.select_next_due_after(since))
    scopes = Repo.one(LearningInput.Query.next_scope_due_after(since, settings))
    UTCDateTime.earliest([scopes | batches])
  end

  def renew(claim, seconds) do
    Repo.transaction(fn ->
      batch = owned!(claim)

      save(batch,
        heartbeat_at: Repo.now!(),
        lease_expires_at: DateTime.add(Repo.now!(), seconds)
      )
    end)
  end

  @doc "Freeze the billable host start before submit; retries of that run do not spend again."
  def begin_execution(claim, run_id) do
    Repo.transaction(fn ->
      batch = owned!(claim)

      other_outstanding =
        batch.scope_key |> outstanding_scope_query() |> LearningRun.Query.excluding_id(run_id)

      if Repo.exists?(other_outstanding), do: Repo.rollback(:learning_remote_outstanding)

      {:ok, run} = authorize_run!(run_id, claim)
      ids = inputs(batch.id) |> Enum.map(& &1.id) |> Enum.sort()

      unless Enum.sort(Enum.map(run.inputs, & &1["source_input_id"])) == ids and
               run.policy == batch.policy and run.policy_digest == batch.policy_digest and
               run.batch_id in [nil, batch.id] and current_request?(batch, run),
             do: Repo.rollback(:learning_batch_mismatch)

      start_once(batch, run)
    end)
  end

  defp start_once(batch, %{started_at: nil} = run) do
    if batch.start_count >= batch.start_limit, do: Repo.rollback(:learning_retry_exhausted)
    save(batch, start_count: batch.start_count + 1)

    run
    |> Ecto.Changeset.change(started_at: Repo.now!(), batch_id: batch.id)
    |> Repo.update!()
  end

  defp start_once(_batch, run), do: run

  def release(claim, reason, delay_seconds) when is_atom(reason) and delay_seconds >= 0 do
    Repo.transaction(fn ->
      batch = owned!(claim)

      terminal = terminal_release?(batch, reason)
      code = release_code(batch, reason)

      if terminal do
        Repo.update_all(unfinished_members(batch.id),
          set: [terminal_reason: code, updated_at: Repo.now!()]
        )
      end

      save(batch,
        lease_ref: nil,
        lease_owner: nil,
        lease_expires_at: nil,
        status: if(terminal, do: :deferred, else: :queued),
        error_code: code,
        # The failing conversation rests; unrelated conversations remain eligible.
        next_attempt_at: DateTime.add(Repo.now!(), if(terminal, do: 3600, else: delay_seconds)),
        completed_at: if(terminal, do: Repo.now!())
      )
    end)
  end

  # Causes another start would meet again, so they stop the batch at once.
  @stopping_reasons [
    :knowledge_target_unavailable,
    :knowledge_match_ambiguous,
    :learning_capacity_exceeded,
    :learning_remote_unresolved
  ]

  defp terminal_release?(batch, reason),
    do: batch.start_count >= batch.start_limit or reason in @stopping_reasons

  # A cause that stops the batch by itself keeps its name even when it also
  # spent the last start: "every start was used" would hide it and invite one
  # more start that meets the same cause.
  defp release_code(batch, reason) do
    if batch.start_count >= batch.start_limit and reason not in @stopping_reasons,
      do: "learning_retry_exhausted",
      else: Atom.to_string(reason)
  end

  def finish(claim, status, reason \\ nil)
      when status in [:applied, :no_change, :deferred, :superseded] do
    Repo.transaction(fn ->
      batch = owned!(claim)

      Repo.update_all(unfinished_members(batch.id),
        set: [terminal_reason: reason || Atom.to_string(status), updated_at: Repo.now!()]
      )

      save(batch,
        lease_ref: nil,
        lease_owner: nil,
        lease_expires_at: nil,
        status: status,
        error_code: reason,
        completed_at: Repo.now!(),
        next_attempt_at: deferred_until(status, reason)
      )
    end)
  end

  # A stale operator selection needs a new selection, not a conversation-wide
  # model-failure cooldown. Outstanding remote custody still blocks the scope.
  defp deferred_until(:deferred, reason)
       when reason in ~w(knowledge_rebuild_conflict learning_batch_mismatch), do: nil

  defp deferred_until(:deferred, _reason), do: DateTime.add(Repo.now!(), 3600)
  defp deferred_until(_status, _reason), do: nil

  def authorize(claim), do: Repo.transaction(fn -> owned!(claim) end)

  @doc """
  Pin a new attempt to Ryker's current learning template. Unstarted prepared
  attempts under the previous template become stale; outstanding attempts keep
  their frozen job authority, and spent starts stay spent.
  """
  def adopt_policy(claim, %{policy: policy, policy_digest: digest}) do
    with_lease(claim, fn ->
      batch = owned!(claim)

      if batch.policy == policy and batch.policy_digest == digest do
        {:ok, %{claim | batch: batch}}
      else
        # An attempt prepared under the old policy never started; it never will.
        batch.id
        |> LearningRun.Query.by_batch_id()
        |> LearningRun.Query.unstarted()
        |> Repo.update_all(
          set: [status: :stale, error_code: "learning_policy_changed", updated_at: Repo.now!()]
        )

        {:ok, %{claim | batch: save(batch, policy: policy, policy_digest: digest)}}
      end
    end)
  end

  @doc """
  Whether the worker already gave a session of this learning policy more than
  an isolated read-only scratch. The policy digest fixes that authority, so
  every further session of it would be refused the same way.
  """
  def policy_refused?(%{policy: policy, policy_digest: digest}) do
    policy
    |> LearningRun.Query.by_policy(digest)
    |> LearningRun.Query.by_error_code("learning_session_not_isolated")
    |> Repo.exists?()
  end

  @doc "Prepare under the same absolute batch budget, including audited extra starts."
  def prepare(claim) do
    # Commit source retirement independently of a later preparation/budget
    # failure. Exclusive memberships must not lose healthy siblings, and a
    # spent start must remain spent even when the replacement manifest shrinks.
    with {:ok, current} <- retire_unavailable(claim) do
      prepare_current(current)
    end
  end

  defp prepare_current(%{inputs: []}), do: {:error, :learning_source_stale}

  defp prepare_current(claim) do
    with_lease(claim, fn ->
      Learning.prepare(Enum.map(inputs(claim.batch.id), & &1.id), %{
        policy: claim.batch.policy,
        policy_digest: claim.batch.policy_digest,
        batch_claim: claim
      })
    end)
  end

  @doc "Retire only unavailable original members, after outstanding remote work has stopped."
  def retire_unavailable(claim) do
    with_lease(claim, fn ->
      batch = owned!(claim)

      if Repo.exists?(outstanding_scope_query(batch.scope_key)),
        do: Repo.rollback(:learning_remote_outstanding)

      # Keep batch -> run -> source lock order. A never-started preparation has
      # disclosed nothing; its bytes remain immutable when its members change.
      unstarted =
        batch.id
        |> LearningRun.Query.by_batch_id()
        |> LearningRun.Query.unstarted()
        |> LearningRun.Query.ordered_by_recent()
        |> LearningRun.Query.limit_to(1)
        |> LearningRun.Query.lock_for_update()
        |> Repo.one()

      valid_ids = current_members!(batch, unfinished_members(batch.id))
      retire_unstarted_manifest!(unstarted, valid_ids)
      Learning.broadcast_learning_updated(batch.id)
      {:ok, %{claim | batch: batch, inputs: inputs(batch.id)}}
    end)
  end

  @doc """
  Leaves out the batch's largest message once the batch is too large to
  learn from at once, so the rest are learned. Deferring the whole batch left
  up to sixteen messages unlearned for good (2026-10-04 review). A rebuild
  relearns one topic from exactly its sources and keeps them all.
  """
  def retire_largest(claim) do
    with_lease(claim, fn ->
      batch = owned!(claim)
      if batch.rebuild_target_id, do: Repo.rollback(:learning_capacity_exceeded)

      batch.id
      |> assigned_inputs()
      |> Enum.max_by(&Learning.input_bytes/1, fn -> nil end)
      |> retire_too_large(batch)

      Learning.broadcast_learning_updated(batch.id)
      {:ok, %{claim | batch: batch, inputs: inputs(batch.id)}}
    end)
  end

  defp retire_too_large(nil, _batch), do: :ok

  defp retire_too_large(largest, batch) do
    batch.id
    |> unfinished_members()
    |> InputMembership.Query.by_input_id(largest.id)
    |> Repo.update_all(
      set: [terminal_reason: "learning_input_too_large", updated_at: Repo.now!()]
    )
  end

  defp current_members!(%{rebuild_target_id: nil} = batch, members),
    do: retire_unavailable_members!(batch, members)

  defp current_members!(batch, _members) do
    case Rebuilds.inputs(batch) do
      [] -> []
      _ -> batch |> Rebuilds.validate_selection!() |> Enum.map(& &1.id)
    end
  end

  defp retire_unstarted_manifest!(nil, _ids), do: :ok

  defp retire_unstarted_manifest!(run, ids) do
    unless Enum.sort(Enum.map(run.inputs, & &1["source_input_id"])) == Enum.sort(ids),
      do: save(run, status: :stale, error_code: "learning_source_stale")
  end

  @doc false
  def preparation_budget!(claim, ids, settings) do
    batch = owned!(claim)

    unless Enum.sort(Enum.map(inputs(batch.id), & &1.id)) == Enum.sort(ids) and
             batch.policy == settings.policy and batch.policy_digest == settings.policy_digest,
           do: Repo.rollback(:learning_batch_mismatch)

    if Repo.exists?(outstanding_scope_query(batch.scope_key)),
      do: Repo.rollback(:learning_remote_outstanding)

    if batch.start_count >= batch.start_limit, do: Repo.rollback(:learning_retry_exhausted)
    batch.start_limit
  end

  @doc false
  def retry_in_transaction(id, expected_version) do
    unless Repo.in_transaction?(), do: raise(ArgumentError, "operator audit transaction required")
    lock_queue!()

    case Repo.one(Batch.Query.by_id(id)) do
      %Batch{rebuild_target_id: target} = batch when not is_nil(target) ->
        target = %{
          version: batch.rebuild_target_version,
          generation: batch.rebuild_target_generation
        }

        Rebuilds.reselect_in_transaction(id, expected_version, target, batch.rebuild_selection)

      _ ->
        retry_learning_batch!(id, expected_version)
    end
  end

  defp retry_learning_batch!(id, expected_version) do
    batch = retryable_batch!(id, expected_version)
    ensure_retry_scope_available!(batch)
    members = retry_members(id)

    valid_ids = retire_unavailable_members!(batch, members)
    if valid_ids == [], do: Repo.rollback(:learning_source_stale)

    settings =
      case Runtime.configured_options() do
        {:ok, settings} -> settings
        {:error, reason} -> Repo.rollback(reason)
      end

    # Never erase spent starts. Each explicit, version-checked operator action
    # allows one more start, not a new batch or an invisible reset of the lifetime
    # bill. Unused starts from a failed grant do not accumulate. The independent
    # version prevents stale-form ABA when this ceiling gets smaller.
    members
    |> InputMembership.Query.by_input_ids(valid_ids)
    |> Repo.update_all(set: [terminal_reason: nil, updated_at: Repo.now!()])

    changed =
      save(batch,
        status: :queued,
        policy: settings.policy,
        policy_digest: settings.policy_digest,
        start_limit: batch.start_count + 1,
        budget_version: batch.budget_version + 1,
        next_attempt_at: nil,
        completed_at: nil,
        error_code: nil
      )

    {:ok, %{previous: retry_document(batch), outcome: retry_document(changed)}}
  end

  defp retryable_batch!(id, expected_version) do
    batch = locked_batch(id)

    unless batch && batch.status == :deferred && batch.budget_version == expected_version,
      do: Repo.rollback(:learning_retry_conflict)

    batch
  end

  defp ensure_retry_scope_available!(batch) do
    if Repo.exists?(outstanding_scope_query(batch.scope_key)),
      do: Repo.rollback(:learning_remote_outstanding)

    other_active =
      batch.scope_key
      |> Batch.Query.by_scope_key()
      |> Batch.Query.excluding_id(batch.id)
      |> Batch.Query.active()

    if Repo.exists?(other_active), do: Repo.rollback(:learning_scope_busy)
  end

  defp retry_members(id) do
    id
    |> InputMembership.Query.by_batch_id()
    |> InputMembership.Query.not_retired_for("source_unavailable")
  end

  defp retire_unavailable_members!(batch, members) do
    ids = members |> InputMembership.Query.select_input_ids() |> Repo.all()

    entries =
      ids
      |> Entry.Query.by_ids()
      |> Entry.Query.ordered_by_id()
      |> Entry.Query.lock_for_share()
      |> Repo.all()

    valid_ids = entries |> Enum.filter(&learnable_entry?(&1, batch)) |> Enum.map(& &1.id)

    members
    |> InputMembership.Query.excluding_input_ids(valid_ids)
    |> Repo.update_all(set: [terminal_reason: "source_unavailable", updated_at: Repo.now!()])

    valid_ids
  end

  defp learnable_entry?(entry, batch) do
    with true <- LearningSources.current_entry?(entry) and same_scope?(entry, batch),
         {:ok, scope} <- Observations.locked_scope(entry, entry.repository_ref),
         sources when is_list(sources) and sources != [] <- LearningSources.for_entry(entry),
         true <- LearningSources.valid?(sources, scope),
         do: true,
         else: (_ -> false)
  end

  defp same_scope?(entry, batch) do
    entry.destination_transport == batch.transport and
      entry.destination_conversation_ref == batch.conversation_ref and
      entry.repository_ref == batch.repository_ref and
      entry.execution_mode == batch.execution_mode
  end

  defp retry_document(batch),
    do: %{
      "batch_id" => batch.id,
      "policy" => batch.policy,
      "policy_digest" => batch.policy_digest,
      "status" => Atom.to_string(batch.status),
      "start_count" => batch.start_count,
      "start_limit" => batch.start_limit,
      "budget_version" => batch.budget_version,
      "error_code" => batch.error_code
    }

  @doc """
  Drops a stopped batch: Ryker stops trying to learn from its messages. Its
  attempts, the starts they used and why it stopped stay recorded; nothing
  learned changes. Only a stopped batch at the budget version the person saw
  can be dropped, and only once no model execution of its conversation is
  still unconfirmed, which reconciliation has to settle first.

  Andrew, 2026-09-27: a batch stuck on a learned topic that lost its own
  messages offered only relearning that topic; "why I can't just
  forget/delete it?"
  """
  def drop_in_transaction(id, expected_version) do
    unless Repo.in_transaction?(), do: raise(ArgumentError, "operator audit transaction required")
    lock_queue!()
    batch = locked_batch(id)

    unless batch && batch.status == :deferred && batch.budget_version == expected_version,
      do: Repo.rollback(:learning_batch_changed)

    if Repo.exists?(outstanding_scope_query(batch.scope_key)),
      do: Repo.rollback(:learning_remote_outstanding)

    dropped = save(batch, status: :dropped, next_attempt_at: nil)
    {:ok, %{previous: retry_document(batch), outcome: retry_document(dropped)}}
  end

  def yield(claim, delay_seconds) when is_integer(delay_seconds) and delay_seconds in 0..300 do
    Repo.transaction(fn ->
      batch = owned!(claim)

      save(batch,
        status: :queued,
        lease_ref: nil,
        lease_owner: nil,
        lease_expires_at: nil,
        next_attempt_at: DateTime.add(Repo.now!(), delay_seconds)
      )
    end)
  end

  @doc "Fence local state changes with batch ownership. Never call a provider inside this callback."
  def with_lease(claim, callback) do
    Repo.transaction(fn ->
      _batch = owned!(claim)

      case callback.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc "The batch's oldest run with no stop proof yet."
  @spec fetch_outstanding(Ecto.UUID.t()) :: {:ok, LearningRun.t()} | {:error, :not_found}
  def fetch_outstanding(batch_id) do
    batch_id
    |> LearningRun.Query.by_batch_id()
    |> LearningRun.Query.unstopped()
    |> LearningRun.Query.ordered_by_oldest()
    |> LearningRun.Query.limit_to(1)
    |> Repo.fetch()
  end

  defp outstanding_scope_query(scope_key),
    do: scope_key |> LearningRun.Query.by_scope() |> LearningRun.Query.unstopped()

  @doc "The batch's latest run of its current attempt."
  @spec fetch_latest(Ecto.UUID.t()) :: {:ok, LearningRun.t()} | {:error, :not_found}
  def fetch_latest(batch_id), do: Repo.fetch(LearningRun.Query.latest_current(batch_id))

  def reconciliation_failed(claim, run_id) do
    with_lease(claim, fn ->
      run =
        run_id
        |> LearningRun.Query.by_id()
        |> LearningRun.Query.by_batch_id(claim.batch.id)
        |> LearningRun.Query.lock_for_update()
        |> Repo.one()

      if is_nil(run), do: Repo.rollback(:learning_batch_mismatch)
      {:ok, save(run, reconcile_attempt_count: run.reconcile_attempt_count + 1)}
    end)
  end

  defp authorize_run!(id, claim) do
    case Learning.authorize(id, claim) do
      {:ok, run} -> {:ok, run}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp next_batch(now), do: Repo.one(Batch.Query.next_claimable(now))

  defp create_batch(settings, now) do
    pending = LearningInput.Query.pending()
    current = processable(pending, now)
    unavailable = LearningInput.Query.unavailable(pending, current)

    # Expired imports are acknowledged in bounded batches, but must not delay
    # learning from current messages or contaminate their input set.
    create_batch(settings, now, current) || create_batch(settings, now, unavailable)
  end

  defp create_batch(settings, now, pending) do
    case Repo.one(LearningInput.Query.next_due_scope(pending, settings, now)) do
      nil -> nil
      scope -> assign_scope(scope, pending, settings, now)
    end
  end

  defp assign_scope(scope, pending, settings, now) do
    entries =
      pending
      |> LearningInput.Query.by_scope(scope)
      |> Entry.Query.ordered_by_oldest()
      |> Entry.Query.limit_to(settings.batch_size)
      |> Entry.Query.lock_for_update()
      |> Repo.all()

    batch =
      Repo.insert!(
        struct!(
          Batch,
          Map.merge(scope, %{
            scope_key: scope_key(scope),
            status: :queued,
            input_count: length(entries),
            policy: settings.policy,
            policy_digest: settings.policy_digest
          })
        )
      )

    ids = Enum.map(entries, & &1.id)

    current =
      ids
      |> Entry.Query.by_ids()
      |> processable(now)
      |> Entry.Query.select_ids()
      |> Repo.all()
      |> MapSet.new()

    rows =
      Enum.map(entries, fn entry ->
        valid =
          is_map(entry.content) and MapSet.member?(current, entry.id)

        %{
          input_id: entry.id,
          batch_id: batch.id,
          terminal_reason: if(not valid, do: "source_unavailable"),
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.insert_all(InputMembership, rows)
    Learning.broadcast_learning_updated(batch.id)
    batch
  end

  defp processable(query, now),
    do: LearningInput.Query.processable(query, now, LearningSources.retention_seconds())

  defp inputs(batch_id) do
    case Repo.one!(Batch.Query.by_id(batch_id)) do
      %{rebuild_target_id: nil} -> assigned_inputs(batch_id)
      batch -> Rebuilds.inputs(batch)
    end
  end

  defp assigned_inputs(batch_id), do: Repo.all(LearningInput.Query.held_by(batch_id))

  defp unfinished_members(batch_id),
    do: batch_id |> InputMembership.Query.by_batch_id() |> InputMembership.Query.unfinished()

  defp locked_batch(id),
    do: id |> Batch.Query.by_id() |> Batch.Query.lock_for_update() |> Repo.one()

  defp current_request?(%{rebuild_target_id: nil}, _run), do: true

  defp current_request?(batch, run) do
    run.batch_budget_version == batch.budget_version and run.rebuild == Rebuilds.contract(batch)
  end

  defp lease(batch, worker, seconds, now) do
    if batch.status == :deferred do
      # This claim is reconciliation of the same unresolved batch. Restore its
      # original membership for the remaining approved budget after stop proof;
      # later arrivals must not replace those inputs or inherit that budget.
      batch.id
      |> InputMembership.Query.by_batch_id()
      |> InputMembership.Query.retired_except("source_unavailable")
      |> Repo.update_all(set: [terminal_reason: nil, updated_at: now])
    end

    batch =
      save(batch,
        status: :running,
        lease_ref: Ecto.UUID.generate(),
        lease_owner: worker,
        heartbeat_at: now,
        lease_expires_at: DateTime.add(now, seconds)
      )

    %{batch: batch, lease_ref: batch.lease_ref, inputs: inputs(batch.id)}
  end

  defp owned!(claim) do
    batch = locked_batch(claim.batch.id)

    unless batch && batch.status == :running && batch.lease_ref == claim.lease_ref &&
             DateTime.compare(batch.lease_expires_at, Repo.now!()) == :gt,
           do: Repo.rollback(:learning_lease_lost)

    batch
  end

  @doc false
  def lock_owned_in_transaction!(claim), do: owned!(claim)

  # A renewal only moves the lease and its heartbeat, which no page shows.
  defp save(row, [heartbeat_at: _heartbeat, lease_expires_at: _expiry] = attrs),
    do: row |> Ecto.Changeset.change(attrs) |> Repo.update!()

  defp save(row, attrs) do
    row
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
    |> tap(&Learning.broadcast_learning_updated(&1.id))
  end
end
