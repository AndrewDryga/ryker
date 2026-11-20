defmodule Ryker.Evals.WorldWorkerLoss do
  @moduledoc """
  Stops the first eval dispatcher after Coop accepts its frozen submission and
  before Ryker can record the response. The replacement uses the ordinary API,
  persisted operation key and claim path. The judge sees only an observed recovery.
  """
  alias Ryker.Coop
  alias Ryker.Repo
  alias Ryker.Work.{Custody, Dispatcher, OperationKeys}

  def run(claim, options, resume) do
    executor = Keyword.fetch!(options, :executor_options)
    binding = {Keyword.fetch!(executor, :api), Keyword.fetch!(executor, :client)}
    first = Keyword.merge(executor, api: __MODULE__, client: binding)
    worker = Keyword.fetch!(options, :worker_ref) <> ":replacement"

    with {:ok, key} <- interrupt(claim, Keyword.put(options, :executor_options, first)),
         :ok <- expire_interrupted_claim(claim, key),
         {:ok, %{turn: %{id: id}} = next} when id == claim.turn.id <-
           Custody.claim_next(worker, 300, :work),
         {:ok, execution} <- resume.(next),
         true <-
           OperationKeys.turn(execution.turn) == key and is_binary(execution.turn.coop_turn_id) do
      receipt = %{
        turn_id: id,
        after_remote_submit: true,
        reconciled_remote_turn_id: execution.turn.coop_turn_id
      }

      {:ok, {:executed, Map.put(execution, :worker_replacements, [receipt])}}
    else
      {:deferred, reason} -> {:ok, {:deferred, reason}}
      {:error, reason} -> {:error, reason}
      _unproven -> {:error, {:world_eval_failed, :worker_replacement_not_reconciled}}
    end
  end

  defp interrupt(claim, options) do
    {pid, monitor} =
      spawn_monitor(fn ->
        case Dispatcher.run_claim(claim, options) do
          {:ok, {:deferred, reason}} -> exit({:before_submit_deferred, reason})
          _other -> :done
        end
      end)

    receive do
      {:DOWN, ^monitor, :process, ^pid, {:after_remote_submit, key}} when is_binary(key) ->
        {:ok, key}

      {:DOWN, ^monitor, :process, ^pid, {:before_submit_deferred, reason}} ->
        {:deferred, reason}

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        {:error, {:world_eval_failed, :worker_did_not_reach_submit}}
    after
      120_000 ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, {:world_eval_failed, :worker_submit_timeout}}
    end
  end

  defp expire_interrupted_claim(claim, key) do
    case Repo.query!(
           """
           UPDATE episode_work_turns SET lease_expires_at = clock_timestamp() - interval '1 second'
           WHERE id = $1 AND lease_ref = $2 AND coop_turn_id IS NULL AND status = 'pending' AND remote_operation_key = $3
           """,
           [Ecto.UUID.dump!(claim.turn.id), claim.lease_ref, key]
         ) do
      %{num_rows: 1} -> :ok
      _lost_claim -> {:error, {:world_eval_failed, :interrupted_claim_changed}}
    end
  end

  # Only the first, interrupted read-only dispatcher uses these callbacks.
  def capabilities({api, client}), do: api.capabilities(client)
  def operation_by_key({api, client}, key), do: api.operation_by_key(client, key)
  def get_session({api, client}, id), do: api.get_session(client, id)

  def prepare_create_session({api, client}, key, policy, task, source),
    do: Coop.API.prepare_create_session(api, client, key, policy, task, source)

  def create_session({api, client}, key, policy, task, source),
    do: api.create_session(client, key, policy, task, source)

  def submit_frozen_turn({api, client}, session, key, revision, submission, binding, artifacts) do
    case api.submit_frozen_turn(client, session, key, revision, submission, binding, artifacts) do
      {:ok, _receipt} -> exit({:after_remote_submit, key})
      failure -> failure
    end
  end
end
