defmodule Ryker.Learning.Batches do
  @moduledoc "Durable, exclusively assigned learning inputs and leased execution budgets."
  import Ecto.Query
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Learning.{Batch, InputMembership, Rebuilds, Runtime}
  alias Ryker.Repo

  alias Ryker.State.{
    ConversationObservation,
    Learning,
    LearningRun,
    LearningSources,
    Observations
  }

  def claim(worker, settings) do
    Repo.transaction(fn ->
      now = Repo.now!()
      Batch.lock_queue!()
      batch = next_batch(now) || create_batch(settings, now)
      if batch, do: lease(batch, worker, settings.lease_seconds, now), else: :idle
    end)
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

      if Repo.exists?(
           from(r in outstanding_scope_query(batch.scope_key), where: r.id != ^run_id)
         ),
         do: Repo.rollback(:learning_remote_outstanding)

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
        Repo.update_all(
          from(m in InputMembership,
            where: m.batch_id == ^batch.id and is_nil(m.terminal_reason)
          ),
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

  defp terminal_release?(batch, reason),
    do:
      batch.start_count >= batch.start_limit or
        reason in [
          :knowledge_target_unavailable,
          :knowledge_match_ambiguous,
          :learning_capacity_exceeded,
          :learning_remote_unresolved
        ]

  defp release_code(batch, reason) do
    if batch.start_count >= batch.start_limit and reason != :learning_remote_unresolved,
      do: "learning_retry_exhausted",
      else: Atom.to_string(reason)
  end

  def finish(claim, status, reason \\ nil)
      when status in [:applied, :no_change, :deferred, :superseded] do
    Repo.transaction(fn ->
      batch = owned!(claim)

      Repo.update_all(
        from(m in InputMembership, where: m.batch_id == ^batch.id and is_nil(m.terminal_reason)),
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
        Repo.one(
          from(r in LearningRun,
            where: r.batch_id == ^batch.id and r.status == :prepared and is_nil(r.started_at),
            order_by: [desc: r.inserted_at, desc: r.id],
            limit: 1,
            lock: "FOR UPDATE"
          )
        )

      members =
        from(m in InputMembership, where: m.batch_id == ^batch.id and is_nil(m.terminal_reason))

      valid_ids = current_members!(batch, members)
      retire_unstarted_manifest!(unstarted, valid_ids)
      {:ok, %{claim | batch: batch, inputs: inputs(batch.id)}}
    end)
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
    Batch.lock_queue!()

    case Repo.get(Batch, id) do
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
    Repo.update_all(from(m in members, where: m.input_id in ^valid_ids),
      set: [terminal_reason: nil, updated_at: Repo.now!()]
    )

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
    batch = Repo.one(from(b in Batch, where: b.id == ^id, lock: "FOR UPDATE"))

    unless batch && batch.status == :deferred && batch.budget_version == expected_version,
      do: Repo.rollback(:learning_retry_conflict)

    batch
  end

  defp ensure_retry_scope_available!(batch) do
    if Repo.exists?(outstanding_scope_query(batch.scope_key)),
      do: Repo.rollback(:learning_remote_outstanding)

    if Repo.exists?(
         from(b in Batch,
           where:
             b.scope_key == ^batch.scope_key and
               b.id != ^batch.id and b.status in [:queued, :running]
         )
       ),
       do: Repo.rollback(:learning_scope_busy)
  end

  defp retry_members(id) do
    from(m in InputMembership,
      where:
        m.batch_id == ^id and
          (is_nil(m.terminal_reason) or m.terminal_reason != "source_unavailable")
    )
  end

  defp retire_unavailable_members!(batch, members) do
    ids = Repo.all(from(m in members, select: m.input_id))

    entries =
      Repo.all(
        from(e in Entry,
          where: e.id in ^ids,
          order_by: [asc: e.id],
          lock: "FOR SHARE"
        )
      )

    valid_ids = entries |> Enum.filter(&learnable_entry?(&1, batch)) |> Enum.map(& &1.id)

    Repo.update_all(from(m in members, where: m.input_id not in ^valid_ids),
      set: [terminal_reason: "source_unavailable", updated_at: Repo.now!()]
    )

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

  defp same_scope?(entry, batch),
    do:
      entry.destination_transport == batch.transport and
        entry.destination_conversation_ref == batch.conversation_ref and
        entry.repository_ref == batch.repository_ref and
        entry.execution_mode == batch.execution_mode

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

  def outstanding(batch_id),
    do:
      Repo.one(
        from(r in LearningRun,
          where:
            r.batch_id == ^batch_id and not is_nil(r.started_at) and is_nil(r.remote_stopped_at),
          order_by: [asc: r.inserted_at, asc: r.id],
          limit: 1
        )
      )

  defp outstanding_scope_query(scope_key) do
    from(r in LearningRun,
      join: b in Batch,
      on: b.id == r.batch_id,
      where:
        b.scope_key == ^scope_key and not is_nil(r.started_at) and is_nil(r.remote_stopped_at)
    )
  end

  def latest(batch_id),
    do:
      Repo.one(
        from(r in LearningRun,
          join: b in Batch,
          on: b.id == r.batch_id,
          where:
            r.batch_id == ^batch_id and
              r.policy == b.policy and r.policy_digest == b.policy_digest and
              (is_nil(b.rebuild_target_id) or r.batch_budget_version == b.budget_version),
          order_by: [desc: r.inserted_at, desc: r.id],
          limit: 1
        )
      )

  def reconciliation_failed(claim, run_id) do
    with_lease(claim, fn ->
      run =
        Repo.one(
          from(r in LearningRun,
            where: r.id == ^run_id and r.batch_id == ^claim.batch.id,
            lock: "FOR UPDATE"
          )
        )

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

  defp next_batch(now) do
    Repo.one(
      from(b in Batch,
        as: :batch,
        where:
          (b.status == :queued and (is_nil(b.next_attempt_at) or b.next_attempt_at <= ^now)) or
            (b.status == :running and b.lease_expires_at <= ^now) or
            (b.status == :deferred and b.next_attempt_at <= ^now and
               exists(subquery(outstanding_parent_batch()))),
        order_by: [asc: b.inserted_at, asc: b.id],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"
      )
    )
  end

  defp outstanding_parent_batch do
    from(r in LearningRun,
      where:
        r.batch_id == parent_as(:batch).id and not is_nil(r.started_at) and
          is_nil(r.remote_stopped_at)
    )
  end

  defp create_batch(settings, now) do
    pending = pending_query()
    current = processable_query(pending, now)

    unavailable =
      from(e in pending, where: e.id not in subquery(from(c in current, select: c.id)))

    # Expired imports are acknowledged in bounded batches, but must not delay
    # learning from current messages or contaminate their input set.
    create_batch(settings, now, current) || create_batch(settings, now, unavailable)
  end

  defp create_batch(settings, now, pending) do
    scopes = coalesced_scopes(pending, settings, now)
    # The exclusion is in SQL before the bounded scope selection; one paused
    # conversation cannot hide healthy scopes behind a recent-candidate cap.
    available =
      from(e in subquery(scopes),
        as: :scope,
        where: not exists(subquery(blocking_scope_batches(now))),
        limit: 1
      )

    case Repo.one(available) do
      nil -> nil
      scope -> assign_scope(scope, pending, settings, now)
    end
  end

  defp coalesced_scopes(pending, settings, now) do
    from(e in pending,
      group_by: [
        e.destination_transport,
        e.destination_conversation_ref,
        e.repository_ref,
        e.execution_mode
      ],
      having:
        max(e.updated_at) <= ^DateTime.add(now, -settings.quiet_seconds) or
          min(e.updated_at) <= ^DateTime.add(now, -settings.maximum_delay_seconds) or
          count(e.id) >= ^settings.batch_size,
      order_by: [asc: min(e.inserted_at), asc: e.destination_conversation_ref],
      select: %{
        transport: e.destination_transport,
        conversation_ref: e.destination_conversation_ref,
        repository_ref: e.repository_ref,
        execution_mode: e.execution_mode
      }
    )
  end

  defp blocking_scope_batches(now) do
    from(b in matching_scope_batches(),
      where:
        b.status in [:queued, :running] or
          (b.status == :deferred and b.next_attempt_at > ^now) or
          exists(subquery(outstanding_parent_scope_batch()))
    )
  end

  defp matching_scope_batches do
    from(b in Batch,
      as: :scope_batch,
      where:
        b.transport == parent_as(:scope).transport and
          b.conversation_ref == parent_as(:scope).conversation_ref and
          fragment("? IS NOT DISTINCT FROM ?", b.repository_ref, parent_as(:scope).repository_ref) and
          b.execution_mode == parent_as(:scope).execution_mode
    )
  end

  defp outstanding_parent_scope_batch do
    from(r in LearningRun,
      where:
        r.batch_id == parent_as(:scope_batch).id and
          not is_nil(r.started_at) and is_nil(r.remote_stopped_at)
    )
  end

  defp assign_scope(scope, pending, settings, now) do
    entries =
      Repo.all(
        from(e in pending,
          where:
            e.destination_transport == ^scope.transport and
              e.destination_conversation_ref == ^scope.conversation_ref and
              fragment("? IS NOT DISTINCT FROM ?", e.repository_ref, ^scope.repository_ref) and
              e.execution_mode == ^scope.execution_mode,
          order_by: [asc: e.inserted_at, asc: e.id],
          limit: ^settings.batch_size,
          lock: "FOR UPDATE"
        )
      )

    batch =
      Repo.insert!(
        struct!(
          Batch,
          Map.merge(scope, %{
            scope_key: Batch.scope_key(scope),
            status: :queued,
            input_count: length(entries),
            policy: settings.policy,
            policy_digest: settings.policy_digest
          })
        )
      )

    ids = Enum.map(entries, & &1.id)

    current =
      from(e in Entry, as: :input, where: e.id in ^ids)
      |> processable_query(now)
      |> select([e], e.id)
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
    batch
  end

  defp pending_query do
    from(e in Entry,
      as: :input,
      where: e.status in [:decided, :superseded],
      where: not exists(from(m in InputMembership, where: m.input_id == parent_as(:input).id))
    )
  end

  defp processable_query(query, now) do
    seconds = LearningSources.retention_seconds()
    cutoff = DateTime.add(now, -(seconds || 0))

    from(e in query,
      where:
        e.status == :decided and e.event_kind != :delete and
          is_nil(e.operational_pruned_at) and not is_nil(e.content),
      where:
        exists(
          from(o in ConversationObservation,
            where:
              o.source_input_id == parent_as(:input).id and
                o.revision == parent_as(:input).revision and
                o.source_fingerprint == parent_as(:input).event_fingerprint and
                (^is_nil(seconds) or o.updated_at > ^cutoff)
          )
        )
    )
  end

  defp inputs(batch_id) do
    case Repo.get!(Batch, batch_id) do
      %{rebuild_target_id: nil} -> assigned_inputs(batch_id)
      batch -> Rebuilds.inputs(batch)
    end
  end

  defp assigned_inputs(batch_id) do
    Repo.all(
      from(e in Entry,
        join: m in InputMembership,
        on: m.input_id == e.id,
        where: m.batch_id == ^batch_id and is_nil(m.terminal_reason),
        order_by: [asc: e.inserted_at, asc: e.id]
      )
    )
  end

  defp current_request?(%{rebuild_target_id: nil}, _run), do: true

  defp current_request?(batch, run),
    do:
      run.batch_budget_version == batch.budget_version and run.rebuild == Rebuilds.contract(batch)

  defp lease(batch, worker, seconds, now) do
    if batch.status == :deferred do
      # This claim is reconciliation of the same unresolved batch. Restore its
      # original membership for the remaining approved budget after stop proof;
      # later arrivals must not replace those inputs or inherit that budget.
      Repo.update_all(
        from(m in InputMembership,
          where: m.batch_id == ^batch.id and m.terminal_reason != "source_unavailable"
        ),
        set: [terminal_reason: nil, updated_at: now]
      )
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
    batch = Repo.one(from(b in Batch, where: b.id == ^claim.batch.id, lock: "FOR UPDATE"))

    unless batch && batch.status == :running && batch.lease_ref == claim.lease_ref &&
             DateTime.compare(batch.lease_expires_at, Repo.now!()) == :gt,
           do: Repo.rollback(:learning_lease_lost)

    batch
  end

  @doc false
  def lock_owned_in_transaction!(claim), do: owned!(claim)

  defp save(row, attrs), do: row |> Ecto.Changeset.change(attrs) |> Repo.update!()
end
