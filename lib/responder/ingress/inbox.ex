defmodule Responder.Ingress.Inbox do
  @moduledoc """
  Transactional, idempotent custody for normalized source inputs.

  Recording does not classify content and does not create an episode. It only
  proves which exact source occurrence a later model decision is about.
  """

  import Ecto.Query

  alias Responder.Artifacts.References, as: ArtifactReferences
  alias Responder.CanonicalJSON
  alias Responder.Ingress.Inbox.{Entry, EntryChangeset}
  alias Responder.Ingress.Input
  alias Responder.Ingress.Projections
  alias Responder.Ingress.WorkProfile
  alias Responder.Repo
  alias Responder.State.{Memories, Observations}

  @ref_prefix "ingress-input:"

  @type receipt :: %{entry: Entry.t(), status: :recorded | :duplicate}
  @type claim :: %{entry: Entry.t(), lease_ref: String.t()}
  @maximum_record_batch 500
  @maximum_revision 9_223_372_036_854_775_807

  @spec record(Input.t(), keyword()) :: {:ok, receipt()} | {:error, term()}
  def record(input, options \\ []) do
    case record_many([input], options) do
      {:ok, [receipt]} -> {:ok, receipt}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Atomically records a bounded provider batch.

  Every input is validated before the transaction. A conflict or persistence
  failure on any member rolls back the entire batch, including projections.
  """
  @spec record_many([Input.t()], keyword()) :: {:ok, [receipt()]} | {:error, term()}
  def record_many(inputs, options \\ []) do
    with {:ok, settings} <- record_options(options),
         {:ok, inputs} <- prepare_inputs(inputs),
         :ok <- slack_addressing_sources(inputs, settings.slack_addressing) do
      Repo.transaction(fn -> record_batch_locked(inputs, settings) end)
      |> transaction_result()
      |> record_rule_inventories(inputs)
    end
  end

  # Written after the custody transaction commits, deliberately outside it.
  # This is evidence about a decision that has already been made: a failed
  # insert inside the transaction would abort the whole batch, which would turn
  # "we could not write down why" into "the message was never accepted".
  defp record_rule_inventories({:ok, receipts} = result, inputs) do
    Enum.zip(inputs, receipts)
    |> Enum.each(fn {input, receipt} ->
      _evidence = Projections.observe_rules(input, ref(receipt.entry))
    end)

    result
  end

  defp record_rule_inventories(result, _inputs), do: result

  @spec fetch(String.t()) :: {:ok, Entry.t()} | :error
  def fetch(@ref_prefix <> id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Entry{} = entry <- Repo.get(Entry, id) do
      {:ok, entry}
    else
      _other -> :error
    end
  end

  def fetch(_ref), do: :error

  @doc """
  The pending input that currently keeps `entry` out of the claimable set, if any.

  This is the same lane predicate the dispatcher claims by: an earlier pending
  input in the same transport, conversation and execution mode, or one whose
  routing lease is still live. It is a current fact about the queue, not a
  history of what blocked the input earlier, and it says nothing once the
  input has left the queue.
  """
  @spec queue_predecessor(Entry.t(), DateTime.t()) :: Entry.t() | nil
  def queue_predecessor(%Entry{status: :pending} = entry, %DateTime{} = now) do
    Repo.one(
      from(other in Entry,
        where: other.status == :pending and other.id != ^entry.id,
        where:
          other.destination_transport == ^entry.destination_transport and
            other.destination_conversation_ref == ^entry.destination_conversation_ref and
            other.execution_mode == ^entry.execution_mode,
        where:
          other.inserted_at < ^entry.inserted_at or
            (other.inserted_at == ^entry.inserted_at and other.id < ^entry.id) or
            (not is_nil(other.lease_ref) and other.lease_expires_at > ^now),
        order_by: [asc: other.inserted_at, asc: other.id],
        limit: 1
      )
    )
  end

  def queue_predecessor(%Entry{}, %DateTime{}), do: nil

  @doc """
  Freezes one exact model-visible admission context for the current execution generation.

  Retries return the original snapshot. A changed snapshot cannot replace it until a
  confirmed terminal execution advances the generation.
  """
  @spec bind_context(String.t(), String.t(), map()) :: {:ok, Entry.t()} | {:error, term()}
  def bind_context(input_ref, lease_ref, context) do
    with {:ok, id} <- input_id(input_ref),
         :ok <- bounded_reference(lease_ref, :lease_ref),
         :ok <- valid_context(context) do
      fingerprint = CanonicalJSON.digest(context)

      Repo.transaction(fn -> bind_context_locked(id, lease_ref, context, fingerprint) end)
      |> transaction_result()
    end
  end

  @doc """
  Claims the oldest eligible input without waiting behind work another executor owns.

  Expired leases are eligible again. The opaque lease reference fences the later
  admission commit or retry update.
  """
  @spec claim_next(String.t(), DateTime.t(), pos_integer()) ::
          {:ok, claim() | nil} | {:error, term()}
  def claim_next(worker_ref, now, lease_seconds) do
    with :ok <- bounded_reference(worker_ref, :worker_ref),
         {:ok, now} <- utc_datetime(now),
         :ok <- positive_integer(lease_seconds, :lease_seconds) do
      Repo.transaction(fn ->
        now
        |> claimable()
        |> claim_entry(worker_ref, now, lease_seconds)
      end)
      |> transaction_result()
    end
  end

  @doc """
  Extends the current fenced lease without changing its owner or attempt count.

  Long Coop operations renew this lease while they are making progress so a
  second worker cannot reclaim healthy in-flight work.
  """
  @spec renew(String.t(), String.t(), DateTime.t(), pos_integer()) ::
          {:ok, Entry.t()} | {:error, term()}
  def renew(input_ref, lease_ref, now, lease_seconds) do
    with {:ok, id} <- input_id(input_ref),
         :ok <- bounded_reference(lease_ref, :lease_ref),
         {:ok, now} <- utc_datetime(now),
         :ok <- positive_integer(lease_seconds, :lease_seconds) do
      Repo.transaction(fn -> renew_locked(id, lease_ref, now, lease_seconds) end)
      |> transaction_result()
    end
  end

  @doc """
  Releases one failed claim for a later retry. Only the current lease holder can do this.
  """
  @spec defer(String.t(), String.t(), DateTime.t(), non_neg_integer(), String.t(), String.t()) ::
          {:ok, Entry.t()} | {:error, term()}
  def defer(input_ref, lease_ref, now, delay_ms, error_code, error_detail) do
    defer(input_ref, lease_ref, now, delay_ms, error_code, error_detail, :same)
  end

  @doc """
  Releases a claim after a confirmed terminal Coop result and advances its operation keys.

  Ambiguous transport failures must use `defer/6` so they reconcile the same keys.
  """
  @spec defer_after_terminal(
          String.t(),
          String.t(),
          DateTime.t(),
          non_neg_integer(),
          String.t(),
          String.t()
        ) :: {:ok, Entry.t()} | {:error, term()}
  def defer_after_terminal(input_ref, lease_ref, now, delay_ms, error_code, error_detail) do
    defer(input_ref, lease_ref, now, delay_ms, error_code, error_detail, :execution)
  end

  @doc """
  Releases a claim after a confirmed validation failure without abandoning its candidate.
  """
  @spec defer_after_validation(
          String.t(),
          String.t(),
          DateTime.t(),
          non_neg_integer(),
          String.t(),
          String.t()
        ) :: {:ok, Entry.t()} | {:error, term()}
  def defer_after_validation(input_ref, lease_ref, now, delay_ms, error_code, error_detail) do
    defer(input_ref, lease_ref, now, delay_ms, error_code, error_detail, :validation)
  end

  @doc """
  Moves an input out of the automatic retry queue when safe replay is impossible.

  The stored error names the exact reconciliation, policy, or operator boundary.
  Confirmed terminal occurrences may advance their generation atomically with
  blocking; ambiguous outcomes must retain the same occurrence for reconciliation.
  """
  @spec block(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, Entry.t()} | {:error, term()}
  @spec block(String.t(), String.t(), String.t(), String.t(), :same | :execution | :validation) ::
          {:ok, Entry.t()} | {:error, term()}
  def block(input_ref, lease_ref, error_code, error_detail, generation \\ :same) do
    with {:ok, id} <- input_id(input_ref),
         :ok <- bounded_reference(lease_ref, :lease_ref),
         :ok <- bounded_text(error_code, 128, :error_code),
         :ok <- bounded_text(error_detail, 4_096, :error_detail),
         :ok <- block_generation(generation) do
      Repo.transaction(fn ->
        block_locked(id, lease_ref, error_code, error_detail, generation)
      end)
      |> transaction_result()
    end
  end

  defp block_generation(generation) when generation in [:same, :execution, :validation], do: :ok
  defp block_generation(_), do: {:error, {:invalid_ingress_execution, :generation}}

  @doc """
  Rearms one exact operator-inspected blocked admission.

  Preserve the context and operation generations left by the blocked attempt.
  Ambiguous operations reconcile the same keys; confirmed terminal operations
  have already advanced their generation and may have cleared the old context.
  """
  @spec rearm(String.t()) :: {:ok, Entry.t()} | {:error, term()}
  def rearm(input_ref) do
    with {:ok, id} <- input_id(input_ref) do
      Repo.transaction(fn -> rearm_locked(id) end)
      |> transaction_result()
    end
  end

  defp defer(input_ref, lease_ref, now, delay_ms, error_code, error_detail, generation) do
    with {:ok, id} <- input_id(input_ref),
         :ok <- bounded_reference(lease_ref, :lease_ref),
         {:ok, now} <- utc_datetime(now),
         :ok <- non_negative_integer(delay_ms, :delay_ms),
         :ok <- bounded_text(error_code, 128, :error_code),
         :ok <- bounded_text(error_detail, 4_096, :error_detail) do
      Repo.transaction(fn ->
        defer_locked(id, lease_ref, now, delay_ms, error_code, error_detail, generation)
      end)
      |> transaction_result()
    end
  end

  @spec ref(Entry.t()) :: String.t()
  def ref(%Entry{id: id}) when is_binary(id), do: @ref_prefix <> id

  defp claim_entry(nil, _worker_ref, _now, _lease_seconds), do: nil

  defp claim_entry(entry, worker_ref, now, lease_seconds) do
    lease_ref = "ingress-lease:#{Ecto.UUID.generate()}"

    attributes = %{
      attempt_count: entry.attempt_count + 1,
      last_error_code: nil,
      last_error_detail: nil,
      lease_expires_at: DateTime.add(now, lease_seconds, :second),
      lease_owner: worker_ref,
      lease_ref: lease_ref,
      next_attempt_at: nil
    }

    case entry |> EntryChangeset.claim(attributes) |> Repo.update() do
      {:ok, claimed} ->
        %{entry: claimed, lease_ref: lease_ref}

      {:error, changeset} ->
        Repo.rollback({:persistence_failed, :ingress_claim, changeset.errors})
    end
  end

  defp claimable(now) do
    Repo.one(
      from(entry in claimable_query(now),
        order_by: [asc: entry.inserted_at, asc: entry.id],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"
      )
    )
  end

  @doc false
  def claimable_query(%DateTime{} = now) do
    # Admission's candidate generation covers the whole destination conversation,
    # including cross-thread history. Serialize that boundary, not the entire
    # inbox. A backoff must not let a later message overtake its missing context.
    predecessor = conversation_predecessor(now)

    from(entry in Entry,
      as: :candidate,
      where: entry.status == :pending,
      where: is_nil(entry.next_attempt_at) or entry.next_attempt_at <= ^now,
      where: is_nil(entry.lease_ref) or entry.lease_expires_at <= ^now,
      where: not exists(subquery(predecessor))
    )
  end

  defp conversation_predecessor(now) do
    from(other in Entry,
      where: other.status == :pending and other.id != parent_as(:candidate).id,
      where:
        other.destination_transport == parent_as(:candidate).destination_transport and
          other.destination_conversation_ref ==
            parent_as(:candidate).destination_conversation_ref and
          other.execution_mode == parent_as(:candidate).execution_mode,
      where:
        other.inserted_at < parent_as(:candidate).inserted_at or
          (other.inserted_at == parent_as(:candidate).inserted_at and
             other.id < parent_as(:candidate).id) or
          (not is_nil(other.lease_ref) and other.lease_expires_at > ^now),
      select: 1
    )
  end

  defp renew_locked(id, lease_ref, now, lease_seconds) do
    case Repo.one(from(entry in Entry, where: entry.id == ^id, lock: "FOR UPDATE")) do
      nil ->
        Repo.rollback({:ingress_renew_failed, :input_not_found})

      %Entry{status: :pending, lease_ref: ^lease_ref} = entry ->
        requested_expiry = DateTime.add(now, lease_seconds, :second)
        lease_expires_at = later_datetime(entry.lease_expires_at, requested_expiry)

        case entry |> EntryChangeset.renew(lease_expires_at) |> Repo.update() do
          {:ok, renewed} ->
            renewed

          {:error, changeset} ->
            Repo.rollback({:persistence_failed, :ingress_renew, changeset.errors})
        end

      %Entry{} ->
        Repo.rollback({:ingress_renew_failed, :lease_lost})
    end
  end

  defp later_datetime(nil, requested), do: requested

  defp later_datetime(current, requested) do
    if DateTime.compare(current, requested) == :lt, do: requested, else: current
  end

  defp defer_locked(id, lease_ref, now, delay_ms, error_code, error_detail, generation) do
    case Repo.one(from(entry in Entry, where: entry.id == ^id, lock: "FOR UPDATE")) do
      nil ->
        Repo.rollback({:ingress_retry_failed, :input_not_found})

      %Entry{status: status} = entry when status in [:decided, :superseded] ->
        entry

      %Entry{lease_ref: ^lease_ref} = entry ->
        {execution_generation, validation_generation} =
          next_generations(entry, generation)

        attributes =
          %{
            execution_generation: execution_generation,
            last_error_code: error_code,
            last_error_detail: error_detail,
            lease_expires_at: nil,
            lease_owner: nil,
            lease_ref: nil,
            next_attempt_at: DateTime.add(now, delay_ms, :millisecond),
            validation_generation: validation_generation
          }
          |> maybe_clear_context(generation)

        case entry |> EntryChangeset.defer(attributes) |> Repo.update() do
          {:ok, deferred} ->
            deferred

          {:error, changeset} ->
            Repo.rollback({:persistence_failed, :ingress_retry, changeset.errors})
        end

      %Entry{} ->
        Repo.rollback({:ingress_retry_failed, :lease_lost})
    end
  end

  defp next_generations(entry, :execution), do: {entry.execution_generation + 1, 1}

  defp next_generations(entry, :validation),
    do: {entry.execution_generation, entry.validation_generation + 1}

  defp next_generations(entry, :same),
    do: {entry.execution_generation, entry.validation_generation}

  defp maybe_clear_context(attributes, :execution) do
    Map.merge(attributes, %{admission_context: nil, admission_context_fingerprint: nil})
  end

  defp maybe_clear_context(attributes, _generation), do: attributes

  defp bind_context_locked(id, lease_ref, context, fingerprint) do
    case Repo.one(from(entry in Entry, where: entry.id == ^id, lock: "FOR UPDATE")) do
      nil ->
        Repo.rollback({:admission_context_failed, :input_not_found})

      %Entry{status: :pending, lease_ref: ^lease_ref, admission_context: nil} = entry ->
        case entry |> EntryChangeset.bind_context(context, fingerprint) |> Repo.update() do
          {:ok, bound} ->
            bound

          {:error, changeset} ->
            Repo.rollback({:persistence_failed, :admission_context, changeset.errors})
        end

      %Entry{
        status: :pending,
        lease_ref: ^lease_ref,
        admission_context_fingerprint: ^fingerprint
      } = entry ->
        entry

      %Entry{status: :pending, lease_ref: ^lease_ref} ->
        Repo.rollback({:admission_context_failed, :snapshot_conflict})

      %Entry{} ->
        Repo.rollback({:admission_context_failed, :lease_lost})
    end
  end

  defp valid_context(context) do
    case CanonicalJSON.validate(context, max_bytes: 98_304) do
      :ok -> :ok
      {:error, _reason} -> {:error, {:invalid_admission_context_snapshot, :document}}
    end
  end

  defp block_locked(id, lease_ref, error_code, error_detail, generation) do
    case Repo.one(from(entry in Entry, where: entry.id == ^id, lock: "FOR UPDATE")) do
      nil ->
        Repo.rollback({:ingress_block_failed, :input_not_found})

      %Entry{status: status} = entry when status in [:blocked, :decided, :superseded] ->
        entry

      %Entry{status: :pending, lease_ref: ^lease_ref} = entry ->
        {execution_generation, validation_generation} = next_generations(entry, generation)

        attributes =
          %{
            execution_generation: execution_generation,
            validation_generation: validation_generation,
            last_error_code: error_code,
            last_error_detail: error_detail,
            lease_expires_at: nil,
            lease_owner: nil,
            lease_ref: nil,
            next_attempt_at: nil,
            status: :blocked
          }
          |> maybe_clear_context(generation)

        case entry |> EntryChangeset.block(attributes) |> Repo.update() do
          {:ok, blocked} ->
            blocked

          {:error, changeset} ->
            Repo.rollback({:persistence_failed, :ingress_block, changeset.errors})
        end

      %Entry{} ->
        Repo.rollback({:ingress_block_failed, :lease_lost})
    end
  end

  defp rearm_locked(id) do
    case Repo.one(from(entry in Entry, where: entry.id == ^id, lock: "FOR UPDATE")) do
      nil ->
        Repo.rollback({:ingress_rearm_failed, :input_not_found})

      %Entry{status: :blocked} = entry ->
        case entry |> EntryChangeset.rearm() |> Repo.update() do
          {:ok, rearmed} ->
            rearmed

          {:error, changeset} ->
            Repo.rollback({:persistence_failed, :ingress_rearm, changeset.errors})
        end

      %Entry{} ->
        Repo.rollback({:ingress_rearm_failed, :input_not_blocked})
    end
  end

  defp record_locked(input, settings) do
    dedupe_key = Input.dedupe_key(input)

    with {:ok, receipt} <- reconcile_record(input, load(dedupe_key), settings),
         :ok <- attach_artifacts(input, receipt),
         :ok <- revoke_answer_memory(receipt),
         :ok <- receive_observation(receipt),
         :ok <- Projections.observe(input, ref(receipt.entry)) do
      {:ok, receipt}
    end
  end

  defp revoke_answer_memory(%{status: :recorded, entry: entry}),
    do: Memories.revoke_answer_source_in_transaction(entry)

  defp revoke_answer_memory(_receipt), do: :ok

  defp receive_observation(%{status: :recorded, entry: entry}),
    do: Observations.receive_in_transaction(entry)

  defp receive_observation(_receipt), do: :ok

  defp record_batch_locked(inputs, settings) do
    case lock_batch(inputs, settings) do
      :ok -> Enum.map(inputs, &record_one_locked!(&1, settings))
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp record_one_locked!(input, settings) do
    case record_locked(input, settings) do
      {:ok, receipt} -> receipt
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp attach_artifacts(_input, %{status: :duplicate, entry: %Entry{operational_pruned_at: at}})
       when not is_nil(at),
       do: :ok

  defp attach_artifacts(input, %{entry: %Entry{id: input_id}}),
    do: ArtifactReferences.attach_input(input, input_id)

  defp reconcile_record(input, nil, %{revision_ties: :exact} = settings),
    do: reconcile(input, nil, settings)

  defp reconcile_record(
         input,
         nil,
         %{revision_ties: :receipt_order} = settings
       ) do
    with {:ok, input} <- allocate_bounded_source_revision(input) do
      reconcile(input, nil, settings)
    end
  end

  defp reconcile_record(
         input,
         nil,
         %{revision_ties: :receipt_order_unbounded} = settings
       ) do
    with {:ok, input} <- allocate_unbounded_source_revision(input) do
      reconcile(input, nil, settings)
    end
  end

  defp reconcile_record(input, %Entry{} = entry, %{revision_ties: revision_ties})
       when revision_ties in [:receipt_order, :receipt_order_unbounded],
       do: reconcile(%{input | revision: entry.revision}, entry, entry.execution_mode)

  defp reconcile_record(input, %Entry{} = entry, %{revision_ties: :exact}),
    do: reconcile(input, entry, entry.execution_mode)

  defp allocate_bounded_source_revision(input) do
    base = input.revision
    maximum = base + 999

    latest =
      Repo.one(
        from(entry in Entry,
          where:
            entry.source_kind == ^input.source.kind and
              entry.source_ref == ^input.source.ref and
              entry.native_input_id == ^input.native_input_id and entry.revision >= ^base and
              entry.revision <= ^maximum,
          select: max(entry.revision)
        )
      )

    cond do
      is_nil(latest) -> {:ok, input}
      latest < maximum -> {:ok, %{input | revision: latest + 1}}
      true -> {:error, {:source_revision_overflow, input.native_input_id, base}}
    end
  end

  defp allocate_unbounded_source_revision(input) do
    latest =
      Repo.one(
        from(entry in Entry,
          where:
            entry.source_kind == ^input.source.kind and
              entry.source_ref == ^input.source.ref and
              entry.native_input_id == ^input.native_input_id,
          select: max(entry.revision)
        )
      )

    cond do
      is_nil(latest) -> {:ok, input}
      latest < @maximum_revision -> {:ok, %{input | revision: latest + 1}}
      true -> {:error, {:source_revision_overflow, input.native_input_id, input.revision}}
    end
  end

  defp lock(dedupe_key) do
    case Repo.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [dedupe_key]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:store_failed, :source_lock, reason}}
    end
  end

  defp lock_batch(inputs, settings) do
    inputs
    |> Enum.flat_map(fn input ->
      keys = [Input.dedupe_key(input)]

      if settings.revision_ties in [:receipt_order, :receipt_order_unbounded],
        do: [revision_lock(input) | keys],
        else: keys
    end)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn key, :ok ->
      case lock(key) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp revision_lock(input) do
    "ingress-revision:" <>
      CanonicalJSON.digest([input.source.kind, input.source.ref, input.native_input_id])
  end

  defp load(dedupe_key) do
    Repo.one(from(entry in Entry, where: entry.dedupe_key == ^dedupe_key, lock: "FOR UPDATE"))
  end

  defp reconcile(input, nil, settings) do
    # Work acceptance uses the database clock. Mixing that with application
    # timestamps can place a follow-up before the answer it follows in the Lab.
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")

    input
    |> EntryChangeset.insert(
      Ecto.UUID.generate(),
      settings.execution_mode,
      settings.work_profile,
      settings.slack_addressing,
      source_envelope: settings.source_envelope,
      engagement_receipt: settings.engagement_receipt
    )
    |> Ecto.Changeset.change(inserted_at: now, updated_at: now)
    |> Repo.insert()
    |> case do
      {:ok, entry} -> {:ok, %{entry: entry, status: :recorded}}
      {:error, changeset} -> {:error, {:persistence_failed, :ingress_input, changeset.errors}}
    end
  end

  defp reconcile(input, %Entry{} = entry, _execution_mode) do
    submitted = Input.fingerprint(input)

    if entry.event_fingerprint == submitted do
      {:ok, %{entry: entry, status: :duplicate}}
    else
      {:error,
       {:input_conflict,
        dedupe_key: entry.dedupe_key,
        stored_fingerprint: entry.event_fingerprint,
        submitted_fingerprint: submitted}}
    end
  end

  defp transaction_result({:ok, receipt}), do: {:ok, receipt}
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp prepare_inputs(inputs)
       when is_list(inputs) and inputs != [] and length(inputs) <= @maximum_record_batch do
    inputs
    |> Enum.reduce_while({:ok, []}, fn input, {:ok, prepared} ->
      case Input.prepare(input) do
        {:ok, input} -> {:cont, {:ok, [input | prepared]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_inputs(_inputs), do: {:error, {:invalid_ingress_execution, :inputs}}

  defp input_id(@ref_prefix <> id) do
    case Ecto.UUID.cast(id) do
      {:ok, normalized} -> {:ok, normalized}
      :error -> {:error, {:invalid_ingress_execution, :input_ref}}
    end
  end

  defp input_id(_input_ref), do: {:error, {:invalid_ingress_execution, :input_ref}}

  defp utc_datetime(%DateTime{} = value) do
    if value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0 do
      {microsecond, _precision} = value.microsecond
      {:ok, %{value | microsecond: {microsecond, 6}}}
    else
      {:error, {:invalid_ingress_execution, :now}}
    end
  end

  defp utc_datetime(_value), do: {:error, {:invalid_ingress_execution, :now}}

  defp bounded_reference(value, field), do: bounded_text(value, 1_024, field)

  defp bounded_text(value, maximum, field) do
    if is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
         String.trim(value) != "" and byte_size(value) <= maximum,
       do: :ok,
       else: {:error, {:invalid_ingress_execution, field}}
  end

  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok

  defp positive_integer(_value, field),
    do: {:error, {:invalid_ingress_execution, field}}

  defp record_options(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) and
         Keyword.keys(options) --
           [
             :execution_mode,
             :revision_ties,
             :work_profile,
             :slack_audience,
             :slack_bot_user_ref,
             :source_envelope,
             :engagement_receipt
           ] ==
           [] do
      revision_ties = Keyword.get(options, :revision_ties, :exact)
      execution_mode = Keyword.get(options, :execution_mode, :live)
      work_profile = Keyword.get(options, :work_profile)
      source_envelope = Keyword.get(options, :source_envelope)
      engagement_receipt = Keyword.get(options, :engagement_receipt)

      with true <- revision_ties in [:exact, :receipt_order, :receipt_order_unbounded],
           true <- execution_mode in [:live, :shadow],
           true <- is_nil(source_envelope) or is_map(source_envelope),
           true <- is_nil(engagement_receipt) or is_map(engagement_receipt),
           {:ok, work_profile} <- WorkProfile.prepare(work_profile),
           {:ok, slack_addressing} <- slack_addressing_options(options) do
        {:ok,
         %{
           execution_mode: execution_mode,
           revision_ties: revision_ties,
           slack_addressing: slack_addressing,
           source_envelope: source_envelope,
           engagement_receipt: engagement_receipt,
           work_profile: work_profile
         }}
      else
        false -> {:error, {:invalid_ingress_execution, :record_options}}
        {:error, _reason} = error -> error
      end
    else
      {:error, {:invalid_ingress_execution, :record_options}}
    end
  end

  defp record_options(_options), do: {:error, {:invalid_ingress_execution, :record_options}}

  defp slack_addressing_options(options) do
    audience = Keyword.get(options, :slack_audience)
    bot_user_ref = Keyword.get(options, :slack_bot_user_ref)

    if (is_nil(audience) and is_nil(bot_user_ref)) or
         (audience in [:ambient, :direct, :mention] and is_binary(bot_user_ref) and
            byte_size(bot_user_ref) <= 256 and Regex.match?(~r/\A[A-Z0-9]+\z/, bot_user_ref)) do
      {:ok, %{audience: audience, bot_user_ref: bot_user_ref}}
    else
      {:error, {:invalid_ingress_execution, :slack_addressing}}
    end
  end

  defp slack_addressing_sources(_inputs, %{audience: nil, bot_user_ref: nil}), do: :ok

  defp slack_addressing_sources(inputs, _addressing) do
    if Enum.all?(inputs, &(&1.source.kind == "slack")),
      do: :ok,
      else: {:error, {:invalid_ingress_execution, :slack_addressing}}
  end

  defp non_negative_integer(value, _field) when is_integer(value) and value >= 0, do: :ok

  defp non_negative_integer(_value, field),
    do: {:error, {:invalid_ingress_execution, field}}
end
