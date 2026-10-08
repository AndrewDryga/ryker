defmodule Ryker.Operator.Emisar do
  @moduledoc """
  Trusted inspection and rearm surface for Emisar approval monitors.

  The surface exposes immutable run identity and bounded failure state. It can
  restart read-only observation after an operator fixes credentials or routing,
  but it cannot approve, deny, repeat, or replace the governed action.

  `failures/1` is what the Failures page lists: a blocked watch a task still
  waits for, and a watch a task waits for that nothing can make progress on
  because its account is not watched or has no usable token. A watch nothing
  waits for any more is not a failure: the monitor closes it
  (`Ryker.Emisar.Approvals.close_ended/1`).
  """
  alias Ryker.Credentials
  alias Ryker.Emisar
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Settings

  # The Failures page reads as deep as the page it shows (a hundred a page).
  @maximum_list 10_001

  @doc """
  Every approval watch a person has to act on, newest first: blocked watches
  a task still waits for, and watches a task waits for whose account is not
  watched or has no usable token.

  Turning monitoring off, or losing the account's token, used to stop every
  such approval without a trace here: the watch was not blocked, so nothing
  was listed while tasks waited for good.
  """
  @spec failures(pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def failures(limit) do
    if is_integer(limit) and limit in 1..@maximum_list do
      unwatched = unwatched_accounts()

      blocked =
        Emisar.Approval.Query.all()
        |> Emisar.Approval.Query.with_joined_origin()
        |> Emisar.Approval.Query.blocked_on_open_cards()
        |> Emisar.Approval.Query.ordered_by_recently_updated()
        |> Emisar.Approval.Query.limit_to(limit)
        |> Emisar.Approval.Query.select_with_origin()
        |> Repo.all()

      stalled_refs = for {ref, stall} <- unwatched, not is_nil(stall), do: ref

      stalled =
        Emisar.Approval.Query.all()
        |> Emisar.Approval.Query.with_joined_origin()
        |> Emisar.Approval.Query.stalled(stalled_refs, Emisar.Approvals.token_unavailable_codes())
        |> Emisar.Approval.Query.ordered_by_recently_updated()
        |> Emisar.Approval.Query.limit_to(limit)
        |> Emisar.Approval.Query.select_with_origin()
        |> Repo.all()

      items =
        (blocked ++ stalled)
        |> Enum.map(&item(&1, unwatched))
        |> Enum.sort_by(&{DateTime.to_unix(&1.updated_at, :microsecond), &1.ref}, :desc)
        |> Enum.take(limit)

      {:ok, items}
    else
      {:error, {:invalid_emisar_approval_operator, :limit}}
    end
  end

  @spec fetch(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(ref) do
    with {:ok, connection_ref, request_id} <- split_ref(ref),
         {_approval, _record, _episode} = row <- watch(connection_ref, request_id) do
      {:ok, item(row, unwatched_accounts())}
    else
      nil -> {:error, :emisar_approval_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp watch(connection_ref, request_id) do
    connection_ref
    |> Emisar.Approval.Query.by_request(request_id)
    |> Emisar.Approval.Query.with_joined_origin()
    |> Emisar.Approval.Query.select_with_origin()
    |> Repo.one()
  end

  @spec rearm(String.t()) :: {:ok, map()} | {:error, term()}
  def rearm(ref) do
    with {:ok, connection_ref, request_id} <- split_ref(ref) do
      Repo.transaction(fn -> rearm_locked(connection_ref, request_id) end)
      |> transaction_result()
    end
  end

  defp rearm_locked(connection_ref, request_id) do
    approval =
      connection_ref
      |> Emisar.Approval.Query.by_request(request_id)
      |> Emisar.Approval.Query.lock_for_update()
      |> Repo.one()

    case approval do
      nil ->
        Repo.rollback(:emisar_approval_not_found)

      %Emisar.Approval{status: :blocked} = approval ->
        with :ok <- exact_open_wait(approval),
             changeset =
               Emisar.Approval.Changeset.update(approval, %{
                 failure_count: 0,
                 last_error: nil,
                 last_error_code: nil,
                 lease_expires_at: nil,
                 lease_owner: nil,
                 lease_ref: nil,
                 next_attempt_at: nil,
                 status: :monitoring
               }),
             {:ok, rearmed} <- Repo.update(changeset) do
          Emisar.Approvals.broadcast_approval_updated(rearmed)
          fetch_locked(rearmed)
        else
          {:error, %Ecto.Changeset{} = changeset} ->
            Repo.rollback({:emisar_approval_persistence_failed, changeset.errors})

          {:error, reason} ->
            Repo.rollback(reason)
        end

      %Emisar.Approval{} ->
        Repo.rollback(:emisar_approval_not_blocked)
    end
  end

  defp fetch_locked(approval) do
    case fetch(operator_ref(approval.connection_ref, approval.request_id)) do
      {:ok, item} -> item
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp exact_open_wait(approval) do
    valid =
      Repo.exists?(Records.Record.Query.awaited_approval(approval.record_id, approval.episode_id))

    if valid, do: :ok, else: {:error, :emisar_approval_wait_stale}
  end

  # Why an account cannot make progress on the approvals waiting on it, if it
  # cannot: approval monitoring is off, or its token is gone. Credential status
  # is metadata only; no token is read here.
  defp unwatched_accounts do
    tokens =
      for %{kind: :emisar, name: name} <- Credentials.statuses(),
          into: MapSet.new(),
          do: name

    Settings.EmisarConnection.Query.all()
    |> Settings.EmisarConnection.Query.select_monitoring()
    |> Repo.all()
    |> Map.new(fn {ref, monitoring} ->
      cond do
        not monitoring -> {ref, :monitoring_off}
        not MapSet.member?(tokens, ref) -> {ref, :token_unavailable}
        true -> {ref, nil}
      end
    end)
  end

  defp item({approval, record, episode}, unwatched) do
    wait = wait(record, episode)

    %{
      action_id: approval.action_id,
      approval_url: approval.approval_url,
      closed_at: approval.closed_at,
      closed_reason: approval.closed_reason,
      connection_ref: approval.connection_ref,
      episode_id: approval.episode_id,
      expires_at: approval.expires_at,
      failure_count: approval.failure_count,
      last_error: approval.last_error,
      last_error_code: approval.last_error_code,
      operation_id: approval.operation_id,
      pack_ref: approval.pack_ref,
      remote_status: approval.remote_status,
      ref: operator_ref(approval.connection_ref, approval.request_id),
      request_id: approval.request_id,
      run_id: approval.run_id,
      runner_ref: approval.runner_ref,
      stall: stall(approval, wait, unwatched),
      status: approval.status,
      updated_at: approval.updated_at,
      wait: wait
    }
  end

  # Whether the task still waits for this approval: `:open` while it does,
  # `:ended` once it never can again (the task was closed or the wait
  # answered), `:elsewhere` when the task is doing something else for now.
  defp wait(record, episode) do
    cond do
      record.status != :open or episode.state == :cancelled ->
        :ended

      episode.state == :waiting_for_event and episode.owner_kind == :event and
          episode.owner_ref == record.ref ->
        :open

      true ->
        :elsewhere
    end
  end

  defp stall(%Emisar.Approval{status: :monitoring} = approval, :open, unwatched) do
    cond do
      stall = Map.get(unwatched, approval.connection_ref) -> stall
      approval.last_error_code in Emisar.Approvals.token_unavailable_codes() -> :token_unavailable
      true -> nil
    end
  end

  defp stall(_approval, _wait, _unwatched), do: nil

  defp split_ref(value) when is_binary(value) do
    case String.split(value, "/", parts: 2) do
      [connection_ref, request_id]
      when byte_size(connection_ref) in 1..64 and byte_size(request_id) in 1..80 ->
        {:ok, connection_ref, request_id}

      _invalid ->
        {:error, {:invalid_emisar_approval_operator, :ref}}
    end
  end

  defp split_ref(_value), do: {:error, {:invalid_emisar_approval_operator, :ref}}

  defp operator_ref(connection_ref, request_id), do: connection_ref <> "/" <> request_id

  defp transaction_result({:ok, value}), do: {:ok, value}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
