defmodule Ryker.Slack.ThreadStatuses do
  @moduledoc """
  Durable, generation-fenced custody for Slack assistant thread statuses.

  Each semantic change and periodic refresh advances one persisted generation.
  A late receipt from an older write therefore cannot settle a newer desired
  status or clear.

  Each status written, confirmed, deferred, blocked or rearmed, and each
  receipt Slack gave for one, is announced after the outermost commit
  (`subscribe_thread_statuses/0`).
  """

  alias Ryker.AdvisoryLock
  alias Ryker.ErrorDetail
  alias Ryker.Repo
  alias Ryker.Slack.ThreadStatus
  alias Ryker.UTCDateTime

  @maximum_targets 1_000
  @phases ~w(queued admitting admission_retry working delivery waiting_for_input waiting_for_event blocked clear)a

  @doc "The most threads one `reconcile/4` takes."
  @spec maximum_targets() :: pos_integer()
  def maximum_targets, do: @maximum_targets

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
    AdvisoryLock.hold!("slack-thread-status:#{workspace_ref}")

    now = Repo.now!()

    existing =
      workspace_ref
      |> ThreadStatus.Query.by_workspace()
      |> ThreadStatus.Query.lock_for_update()
      |> Repo.all()

    target_map = Map.new(targets, &{{&1.channel_ref, &1.thread_ref}, &1})
    existing_map = Map.new(existing, &{{&1.channel_ref, &1.thread_ref}, &1})
    {dropped, kept} = Enum.split_with(existing, &drop?(&1, target_map, now))
    Enum.each(dropped, &drop!/1)

    updated =
      Enum.map(kept, fn status ->
        target = target_or_clear(target_map, status)
        reconcile_existing!(status, target, now, minimum_interval_ms, refresh_interval_ms)
      end)

    inserted =
      targets
      |> Enum.reject(&Map.has_key?(existing_map, {&1.channel_ref, &1.thread_ref}))
      |> Enum.map(&insert!(&1, workspace_ref))

    updated ++ inserted
  end

  # A status that leaves before Slack ever showed it has nothing to clear, and
  # a clear Slack refused is not tried again: a status lapses by itself once
  # Ryker stops refreshing it. The first was written as a clear to a thread
  # showing nothing, and the second stayed blocked for good, one more for every
  # thread (2026-10-04 review). A write in flight finishes first.
  defp drop?(status, target_map, now) do
    not Map.has_key?(target_map, {status.channel_ref, status.thread_ref}) and
      not leased?(status, now) and
      (status.delivered_generation == 0 or {status.phase, status.status} == {:clear, :blocked})
  end

  defp leased?(%ThreadStatus{lease_expires_at: %DateTime{} = expires_at}, now),
    do: DateTime.compare(expires_at, now) == :gt

  defp leased?(_status, _now), do: false

  defp drop!(status) do
    Repo.delete!(status)
    broadcast_thread_status_updated(status)
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

  @doc """
  The earliest moment after `since` at which a status of `workspace_ref` is
  due by the clock alone: a write paced behind the last one or retried after
  a refusal, the lease of a write nobody renewed running out, or a shown
  status due its periodic refresh before Slack lets it lapse. Nil when
  nothing waits on the clock.
  """
  @spec next_due_at(String.t(), DateTime.t(), pos_integer()) :: DateTime.t() | nil
  def next_due_at(workspace_ref, %DateTime{} = since, refresh_interval_ms)
      when is_binary(workspace_ref) and is_integer(refresh_interval_ms) do
    refresh_since = DateTime.add(since, -refresh_interval_ms, :millisecond)

    [next_attempt, lease, delivered] =
      workspace_ref
      |> ThreadStatus.Query.select_next_due_after(since, refresh_since)
      |> Repo.one()

    refresh = delivered && DateTime.add(delivered, refresh_interval_ms, :millisecond)
    UTCDateTime.earliest([next_attempt, lease, refresh])
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
    now = Repo.now!()

    next = workspace_ref |> ThreadStatus.Query.next_claimable(now) |> Repo.one()

    case next do
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

  @doc """
  Writes the status again after `retry_ms`. With `counted: false` the attempt
  just made is given back, for a wait Slack asked for rather than a failure.
  """
  @spec defer(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), pos_integer(), term(), keyword()) ::
          {:ok, ThreadStatus.t()} | {:error, term()}
  def defer(id, lease_ref, generation, retry_ms, reason, options \\ []) do
    with :ok <- milliseconds(retry_ms, :retry_ms) do
      mutate_claim(id, lease_ref, generation, fn status, now ->
        {code, detail} = describe_error(reason)

        update!(status, %{
          attempt_count: given_back(status.attempt_count, options),
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

  defp given_back(attempt_count, options) do
    if Keyword.get(options, :counted, true), do: attempt_count, else: max(attempt_count - 1, 0)
  end

  @doc """
  Stops writing one status until a person rearms it or a newer desired status
  replaces it: Slack said the thread or channel is gone, or the write spent
  every attempt it had.
  """
  @spec block(Ecto.UUID.t(), Ecto.UUID.t(), pos_integer(), term()) ::
          {:ok, ThreadStatus.t()} | {:error, term()}
  def block(id, lease_ref, generation, reason) do
    mutate_claim(id, lease_ref, generation, fn status, _now ->
      {code, detail} = describe_error(reason)

      update!(status, %{
        last_error_code: code,
        last_error_detail: detail,
        lease_expires_at: nil,
        lease_owner: nil,
        lease_ref: nil,
        next_attempt_at: nil,
        status: :blocked
      })
    end)
  end

  @doc """
  Rearms one exact blocked status after operator inspection: the same desired
  text is written again, at once, with a fresh attempt budget.
  """
  @spec rearm(Ecto.UUID.t()) :: {:ok, ThreadStatus.t()} | {:error, term()}
  def rearm(id) do
    with {:ok, id} <- uuid(id, :id) do
      Repo.transaction(fn -> rearm_locked(id) end)
      |> transaction_result()
    end
  end

  defp rearm_locked(id) do
    locked =
      id |> ThreadStatus.Query.by_id() |> ThreadStatus.Query.lock_for_update() |> Repo.one()

    case locked do
      nil ->
        Repo.rollback(:slack_thread_status_not_found)

      %ThreadStatus{status: :blocked} = status ->
        update!(status, %{
          attempt_count: 0,
          last_error_code: nil,
          last_error_detail: nil,
          lease_expires_at: nil,
          lease_owner: nil,
          lease_ref: nil,
          next_attempt_at: nil,
          status: :pending
        })

      %ThreadStatus{} ->
        Repo.rollback(:slack_thread_status_not_blocked)
    end
  end

  # A new generation is a new write with its own attempt budget, whether the
  # last one was delivered, is still pending or was blocked.
  defp reconcile_existing!(status, target, now, minimum_interval_ms, refresh_interval_ms) do
    changed =
      status.phase != target.phase or status.desired_text != target.status or
        status.origin_kind != target[:origin_kind] or status.origin_id != target[:origin_id]

    refresh = refresh_due?(status, now, refresh_interval_ms)

    if changed or refresh do
      update!(status, %{
        attempt_count: 0,
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

    changeset = ThreadStatus.Changeset.insert(attributes)

    case Repo.insert(changeset) do
      {:ok, status} ->
        tap(status, &broadcast_thread_status_updated/1)

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
    now = Repo.now!()

    status =
      id |> ThreadStatus.Query.by_id() |> ThreadStatus.Query.lock_for_update() |> Repo.one()

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
    changeset = ThreadStatus.Changeset.update(status, attributes)

    case Repo.update(changeset) do
      {:ok, status} ->
        tap(status, &broadcast_thread_status_updated/1)

      {:error, changeset} ->
        Repo.rollback({:slack_thread_status_persistence_failed, changeset.errors})
    end
  end

  defp targets(values) when is_list(values) and length(values) <= @maximum_targets do
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

  defp describe_error(reason) do
    code =
      reason
      |> case do
        value when is_atom(value) -> Atom.to_string(value)
        {value, _detail} when is_atom(value) -> Atom.to_string(value)
        _other -> "slack_thread_status_error"
      end
      |> byte_slice(128)

    {code, ErrorDetail.detail(reason)}
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

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Subscribes the caller to Slack thread status changes:
  `{:thread_status_updated, status_id}` once the status Ryker shows in a
  thread is set, confirmed, deferred, blocked or rearmed, or Slack answers a
  write of it, and that change has committed.
  """
  def subscribe_thread_statuses, do: Ryker.PubSub.subscribe(thread_statuses_topic())

  def unsubscribe_thread_statuses, do: Ryker.PubSub.unsubscribe(thread_statuses_topic())

  @doc """
  Internal — announces, after the outermost commit, that `status` changed.
  `Ryker.Slack.ThreadStatusReceipts`, which records what Slack answered,
  calls it too. A status for a request is heard on the request's topics.
  """
  @spec broadcast_thread_status_updated(ThreadStatus.t()) :: :ok
  def broadcast_thread_status_updated(%ThreadStatus{id: id} = status) do
    if status.origin_kind == "episode",
      do: Ryker.Episodes.broadcast_episode_updated(status.origin_id)

    Repo.after_commit(fn ->
      Ryker.PubSub.broadcast(thread_statuses_topic(), {:thread_status_updated, id})
    end)
  end

  defp thread_statuses_topic, do: "slack:thread_statuses"
end
