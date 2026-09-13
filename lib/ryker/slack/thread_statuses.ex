defmodule Ryker.Slack.ThreadStatuses do
  @moduledoc """
  Durable, generation-fenced custody for Slack assistant thread statuses.

  Each semantic change and periodic refresh advances one persisted generation.
  A late receipt from an older write therefore cannot settle a newer desired
  status or clear.
  """

  import Ecto.Query

  alias Ryker.Repo
  alias Ryker.Slack.{ThreadStatus, ThreadStatusChangeset}

  @maximum_error_detail_bytes 4_096
  @phases ~w(queued admitting admission_retry working delivery waiting_for_input waiting_for_event blocked clear)a

  @spec reconcile(String.t(), [map()], pos_integer(), pos_integer()) ::
          {:ok, [ThreadStatus.t()]} | {:error, term()}
  def reconcile(workspace_ref, targets, minimum_interval_ms, refresh_interval_ms) do
    with :ok <- reference(workspace_ref, :workspace_ref),
         :ok <- milliseconds(minimum_interval_ms, :minimum_interval_ms),
         :ok <- milliseconds(refresh_interval_ms, :refresh_interval_ms),
         {:ok, targets} <- targets(targets) do
      Repo.transaction(fn ->
        reconcile_locked(workspace_ref, targets, minimum_interval_ms, refresh_interval_ms)
      end)
      |> transaction_result()
    end
  end

  defp reconcile_locked(workspace_ref, targets, minimum_interval_ms, refresh_interval_ms) do
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "slack-thread-status:#{workspace_ref}"
    ])

    now = database_now!()

    existing =
      Repo.all(
        from(status in ThreadStatus,
          where: status.workspace_ref == ^workspace_ref,
          lock: "FOR UPDATE"
        )
      )

    target_map = Map.new(targets, &{{&1.channel_ref, &1.thread_ref}, &1})
    existing_map = Map.new(existing, &{{&1.channel_ref, &1.thread_ref}, &1})

    updated =
      Enum.map(existing, fn status ->
        target = target_or_clear(target_map, status)
        reconcile_existing!(status, target, now, minimum_interval_ms, refresh_interval_ms)
      end)

    inserted =
      targets
      |> Enum.reject(&Map.has_key?(existing_map, {&1.channel_ref, &1.thread_ref}))
      |> Enum.map(&insert!(&1, workspace_ref))

    updated ++ inserted
  end

  defp target_or_clear(target_map, status) do
    Map.get(target_map, {status.channel_ref, status.thread_ref}, %{
      channel_ref: status.channel_ref,
      phase: :clear,
      status: "",
      thread_ref: status.thread_ref,
      origin_kind: status.origin_kind,
      origin_id: status.origin_id
    })
  end

  @spec claim_next(String.t(), String.t(), pos_integer()) ::
          {:ok, ThreadStatus.t() | nil} | {:error, term()}
  def claim_next(worker_ref, workspace_ref, lease_seconds) do
    with :ok <- reference(worker_ref, :worker_ref),
         :ok <- reference(workspace_ref, :workspace_ref),
         :ok <- seconds(lease_seconds, :lease_seconds) do
      Repo.transaction(fn -> claim_next_locked(worker_ref, workspace_ref, lease_seconds) end)
      |> transaction_result()
    end
  end

  defp claim_next_locked(worker_ref, workspace_ref, lease_seconds) do
    now = database_now!()

    query =
      from(status in ThreadStatus,
        where:
          status.workspace_ref == ^workspace_ref and status.status == :pending and
            (is_nil(status.next_attempt_at) or status.next_attempt_at <= ^now) and
            (is_nil(status.lease_expires_at) or status.lease_expires_at <= ^now),
        order_by: [asc: status.updated_at, asc: status.id],
        limit: 1,
        lock: "FOR UPDATE SKIP LOCKED"
      )

    case Repo.one(query) do
      nil -> nil
      %ThreadStatus{} = status -> lease!(status, worker_ref, lease_seconds, now)
    end
  end

  defp lease!(status, worker_ref, lease_seconds, now) do
    update!(status, %{
      attempt_count: status.attempt_count + 1,
      lease_expires_at: DateTime.add(now, lease_seconds, :second),
      lease_owner: worker_ref,
      lease_ref: Ecto.UUID.generate(),
      next_attempt_at: nil
    })
  end

  @spec confirm(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer()) ::
          {:ok, ThreadStatus.t()} | {:error, term()}
  def confirm(id, lease_ref, generation) do
    mutate_claim(id, lease_ref, generation, fn status, now ->
      update!(status, %{
        delivered_at: now,
        delivered_generation: generation,
        last_error_code: nil,
        last_error_detail: nil,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: nil,
        status: :delivered
      })
    end)
  end

  @spec defer(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), pos_integer(), term()) ::
          {:ok, ThreadStatus.t()} | {:error, term()}
  def defer(id, lease_ref, generation, retry_ms, reason) do
    with :ok <- milliseconds(retry_ms, :retry_ms) do
      mutate_claim(id, lease_ref, generation, fn status, now ->
        {code, detail} = describe_error(reason)

        update!(status, %{
          last_error_code: code,
          last_error_detail: detail,
          lease_expires_at: nil,
          lease_owner: nil,
          lease_ref: nil,
          next_attempt_at: DateTime.add(now, retry_ms, :millisecond)
        })
      end)
    end
  end

  defp reconcile_existing!(status, target, now, minimum_interval_ms, refresh_interval_ms) do
    changed =
      status.phase != target.phase or status.desired_text != target.status or
        status.origin_kind != target[:origin_kind] or status.origin_id != target[:origin_id]

    refresh = refresh_due?(status, now, refresh_interval_ms)

    if changed or refresh do
      update!(status, %{
        desired_text: target.status,
        origin_kind: target[:origin_kind],
        origin_id: target[:origin_id],
        generation: status.generation + 1,
        last_error_code: nil,
        last_error_detail: nil,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: paced_until(status.delivered_at, now, minimum_interval_ms),
        phase: target.phase,
        status: :pending
      })
    else
      status
    end
  end

  defp refresh_due?(
         %ThreadStatus{desired_text: desired, status: :delivered, delivered_at: %DateTime{} = at},
         now,
         refresh_interval_ms
       )
       when desired != "" do
    DateTime.compare(DateTime.add(at, refresh_interval_ms, :millisecond), now) != :gt
  end

  defp refresh_due?(_status, _now, _refresh_interval_ms), do: false

  defp paced_until(nil, _now, _minimum_interval_ms), do: nil

  defp paced_until(delivered_at, now, minimum_interval_ms) do
    due_at = DateTime.add(delivered_at, minimum_interval_ms, :millisecond)
    if DateTime.compare(due_at, now) == :gt, do: due_at, else: nil
  end

  defp insert!(target, workspace_ref) do
    attributes = %{
      channel_ref: target.channel_ref,
      delivered_generation: 0,
      desired_text: target.status,
      origin_kind: target[:origin_kind],
      origin_id: target[:origin_id],
      generation: 1,
      id: Ecto.UUID.generate(),
      phase: target.phase,
      status: :pending,
      thread_ref: target.thread_ref,
      workspace_ref: workspace_ref
    }

    case attributes |> ThreadStatusChangeset.insert() |> Repo.insert() do
      {:ok, status} ->
        status

      {:error, changeset} ->
        Repo.rollback({:slack_thread_status_persistence_failed, changeset.errors})
    end
  end

  defp mutate_claim(id, lease_ref, generation, callback) do
    with {:ok, id} <- uuid(id, :id),
         {:ok, lease_ref} <- uuid(lease_ref, :lease_ref),
         :ok <- positive(generation, :generation) do
      Repo.transaction(fn -> mutate_claim_locked(id, lease_ref, generation, callback) end)
      |> transaction_result()
    end
  end

  defp mutate_claim_locked(id, lease_ref, generation, callback) do
    now = database_now!()
    status = Repo.one(from(status in ThreadStatus, where: status.id == ^id, lock: "FOR UPDATE"))

    cond do
      is_nil(status) ->
        Repo.rollback(:slack_thread_status_not_found)

      status.lease_ref != lease_ref ->
        Repo.rollback(:slack_thread_status_lease_lost)

      status.generation != generation ->
        Repo.rollback(:slack_thread_status_lease_lost)

      DateTime.compare(status.lease_expires_at, now) != :gt ->
        Repo.rollback(:slack_thread_status_lease_lost)

      true ->
        callback.(status, now)
    end
  end

  defp update!(status, attributes) do
    case status |> ThreadStatusChangeset.update(attributes) |> Repo.update() do
      {:ok, status} ->
        status

      {:error, changeset} ->
        Repo.rollback({:slack_thread_status_persistence_failed, changeset.errors})
    end
  end

  defp targets(values) when is_list(values) and length(values) <= 1_000 do
    with true <- Enum.all?(values, &target?/1),
         keys <- Enum.map(values, &{&1.channel_ref, &1.thread_ref}),
         true <- Enum.uniq(keys) == keys do
      {:ok, values}
    else
      _invalid -> {:error, {:invalid_slack_thread_status, :targets}}
    end
  end

  defp targets(_values), do: {:error, {:invalid_slack_thread_status, :targets}}

  defp target?(%{channel_ref: channel, phase: phase, status: status, thread_ref: thread}) do
    phase in @phases and
      is_binary(channel) and Regex.match?(~r/\A[A-Z0-9]+\z/, channel) and
      is_binary(thread) and Regex.match?(~r/\A[0-9]{10,}\.[0-9]{1,6}\z/, thread) and
      is_binary(status) and String.valid?(status) and byte_size(status) <= 100 and
      :binary.match(status, <<0>>) == :nomatch
  end

  defp target?(_target), do: false

  defp database_now! do
    %{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  defp describe_error(reason) do
    code =
      reason
      |> case do
        value when is_atom(value) -> Atom.to_string(value)
        {value, _detail} when is_atom(value) -> Atom.to_string(value)
        _other -> "slack_thread_status_error"
      end
      |> byte_slice(128)

    detail =
      reason
      |> inspect(limit: 30, printable_limit: 3_000)
      |> byte_slice(@maximum_error_detail_bytes)

    {code, detail}
  end

  defp byte_slice(value, maximum) do
    if byte_size(value) <= maximum do
      value
    else
      value
      |> String.graphemes()
      |> Enum.reduce_while("", &append_grapheme(&1, &2, maximum))
    end
  end

  defp append_grapheme(grapheme, output, maximum) do
    if byte_size(output) + byte_size(grapheme) <= maximum,
      do: {:cont, output <> grapheme},
      else: {:halt, output}
  end

  defp reference(value, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
         String.trim(value) != "" and :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, {:invalid_slack_thread_status, field}}
  end

  defp milliseconds(value, field) do
    if is_integer(value) and value in 1..3_600_000,
      do: :ok,
      else: {:error, {:invalid_slack_thread_status, field}}
  end

  defp seconds(value, field) do
    if is_integer(value) and value in 5..3_600,
      do: :ok,
      else: {:error, {:invalid_slack_thread_status, field}}
  end

  defp positive(value, field) do
    if is_integer(value) and value > 0,
      do: :ok,
      else: {:error, {:invalid_slack_thread_status, field}}
  end

  defp uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:invalid_slack_thread_status, field}}
    end
  end

  defp transaction_result({:ok, result}), do: {:ok, result}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
