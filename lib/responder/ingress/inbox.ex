defmodule Responder.Ingress.Inbox do
  @moduledoc """
  Transactional, idempotent custody for normalized source inputs.

  Recording does not classify content and does not create an episode. It only
  proves which exact source occurrence a later model decision is about.
  """

  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.Ingress.Inbox.{Entry, EntryChangeset}
  alias Responder.Ingress.Input
  alias Responder.Repo

  @ref_prefix "ingress-input:"

  @type receipt :: %{entry: Entry.t(), status: :recorded | :duplicate}
  @type claim :: %{entry: Entry.t(), lease_ref: String.t()}

  @spec record(Input.t()) :: {:ok, receipt()} | {:error, term()}
  def record(input) do
    with {:ok, input} <- Input.prepare(input) do
      input
      |> record_transaction()
      |> transaction_result()
    end
  end

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
  """
  @spec block(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, Entry.t()} | {:error, term()}
  def block(input_ref, lease_ref, error_code, error_detail) do
    with {:ok, id} <- input_id(input_ref),
         :ok <- bounded_reference(lease_ref, :lease_ref),
         :ok <- bounded_text(error_code, 128, :error_code),
         :ok <- bounded_text(error_detail, 4_096, :error_detail) do
      Repo.transaction(fn -> block_locked(id, lease_ref, error_code, error_detail) end)
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
      from(entry in Entry,
        where: entry.status == :pending,
        where: is_nil(entry.next_attempt_at) or entry.next_attempt_at <= ^now,
        where: is_nil(entry.lease_ref) or entry.lease_expires_at <= ^now,
        order_by: [asc: entry.inserted_at, asc: entry.id],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"
      )
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

  defp block_locked(id, lease_ref, error_code, error_detail) do
    case Repo.one(from(entry in Entry, where: entry.id == ^id, lock: "FOR UPDATE")) do
      nil ->
        Repo.rollback({:ingress_block_failed, :input_not_found})

      %Entry{status: status} = entry when status in [:blocked, :decided, :superseded] ->
        entry

      %Entry{status: :pending, lease_ref: ^lease_ref} = entry ->
        attributes = %{
          last_error_code: error_code,
          last_error_detail: error_detail,
          lease_expires_at: nil,
          lease_owner: nil,
          lease_ref: nil,
          next_attempt_at: nil,
          status: :blocked
        }

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

  defp record_transaction(input) do
    Repo.transaction(fn ->
      dedupe_key = Input.dedupe_key(input)

      with :ok <- lock(dedupe_key),
           {:ok, receipt} <- reconcile(input, load(dedupe_key)) do
        receipt
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp lock(dedupe_key) do
    case Repo.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [dedupe_key]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, {:store_failed, :source_lock, reason}}
    end
  end

  defp load(dedupe_key) do
    Repo.one(from(entry in Entry, where: entry.dedupe_key == ^dedupe_key, lock: "FOR UPDATE"))
  end

  defp reconcile(input, nil) do
    input
    |> EntryChangeset.insert(Ecto.UUID.generate())
    |> Repo.insert()
    |> case do
      {:ok, entry} -> {:ok, %{entry: entry, status: :recorded}}
      {:error, changeset} -> {:error, {:persistence_failed, :ingress_input, changeset.errors}}
    end
  end

  defp reconcile(input, %Entry{} = entry) do
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

  defp non_negative_integer(value, _field) when is_integer(value) and value >= 0, do: :ok

  defp non_negative_integer(_value, field),
    do: {:error, {:invalid_ingress_execution, field}}
end
