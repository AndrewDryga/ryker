defmodule Ryker.Emisar.Operator do
  @moduledoc """
  Trusted inspection and rearm surface for blocked Emisar approval monitors.

  The surface exposes immutable run identity and bounded failure state. It can
  restart read-only observation after an operator fixes credentials or routing,
  but it cannot approve, deny, repeat, or replace the governed action.
  """

  import Ecto.Query

  alias Ryker.Emisar.{Approval, ApprovalChangeset}
  alias Ryker.Episodes.Episode
  alias Ryker.Repo
  alias Ryker.State.Record

  @maximum_list 500

  @spec list_blocked(pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def list_blocked(limit \\ 100) do
    if is_integer(limit) and limit in 1..@maximum_list do
      items =
        Repo.all(
          from(approval in Approval,
            where: approval.status == :blocked,
            order_by: [asc: approval.updated_at, asc: approval.id],
            limit: ^limit
          )
        )

      {:ok, Enum.map(items, &item/1)}
    else
      {:error, {:invalid_emisar_approval_operator, :limit}}
    end
  end

  @spec fetch(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(request_id) do
    with :ok <- request_id(request_id),
         %Approval{} = approval <- Repo.get_by(Approval, request_id: request_id) do
      {:ok, item(approval)}
    else
      nil -> {:error, :emisar_approval_not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec rearm(String.t()) :: {:ok, map()} | {:error, term()}
  def rearm(request_id) do
    with :ok <- request_id(request_id) do
      Repo.transaction(fn -> rearm_locked(request_id) end)
      |> transaction_result()
    end
  end

  defp rearm_locked(request_id) do
    approval =
      Repo.one(
        from(approval in Approval,
          where: approval.request_id == ^request_id,
          lock: "FOR UPDATE"
        )
      )

    case approval do
      nil ->
        Repo.rollback(:emisar_approval_not_found)

      %Approval{status: :blocked} = approval ->
        with :ok <- exact_open_wait(approval),
             {:ok, rearmed} <-
               approval
               |> ApprovalChangeset.update(%{
                 failure_count: 0,
                 last_error: nil,
                 lease_expires_at: nil,
                 lease_owner: nil,
                 lease_ref: nil,
                 next_attempt_at: nil,
                 status: :monitoring
               })
               |> Repo.update() do
          item(rearmed)
        else
          {:error, %Ecto.Changeset{} = changeset} ->
            Repo.rollback({:emisar_approval_persistence_failed, changeset.errors})

          {:error, reason} ->
            Repo.rollback(reason)
        end

      %Approval{} ->
        Repo.rollback(:emisar_approval_not_blocked)
    end
  end

  defp exact_open_wait(approval) do
    valid =
      Repo.exists?(
        from(record in Record,
          join: episode in Episode,
          on: episode.id == record.episode_id,
          where:
            record.id == ^approval.record_id and record.episode_id == ^approval.episode_id and
              record.kind == "emisar_approval" and record.status == :open and
              episode.state == :waiting_for_event and episode.owner_kind == :event and
              episode.owner_ref == record.ref
        )
      )

    if valid, do: :ok, else: {:error, :emisar_approval_wait_stale}
  end

  defp item(approval) do
    %{
      action_id: approval.action_id,
      approval_url: approval.approval_url,
      episode_id: approval.episode_id,
      failure_count: approval.failure_count,
      last_error: approval.last_error,
      operation_id: approval.operation_id,
      pack_ref: approval.pack_ref,
      remote_status: approval.remote_status,
      request_id: approval.request_id,
      run_id: approval.run_id,
      runner_ref: approval.runner_ref,
      status: approval.status,
      updated_at: approval.updated_at
    }
  end

  defp request_id(value) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..80 and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: :ok,
       else: {:error, {:invalid_emisar_approval_operator, :request_id}}
  end

  defp transaction_result({:ok, value}), do: {:ok, value}
  defp transaction_result({:error, reason}), do: {:error, reason}
end
