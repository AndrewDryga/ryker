defmodule Ryker.StateTools.CallLog do
  @moduledoc """
  What Ryker received and answered for each call to its own state tools.

  Coop's worker keeps tool arguments and error output on the worker: its
  narration of a call names the server and the tool, and of a failure only
  its status. Ryker serves these tools itself, so it keeps the one account a
  timeline can show of why a call was refused: the arguments, bounded and
  redacted the way retained activity is, and the error the model read back.
  The records go when their turn's bodies expire.
  """

  import Ecto.Query

  alias Ryker.Repo
  alias Ryker.StateTools.CallRecord
  alias Ryker.Work.{Activity, Turn}

  @maximum_listed 5_000

  @doc """
  Keeps one answered call. Recording is best effort and never changes the
  answer: a call without an active Work turn, or a write that fails, is
  simply not kept.
  """
  @spec record(term(), term(), term(), {:ok, term()} | {:error, term()}, DateTime.t()) :: :ok
  def record(%{turn: %{id: turn_id}}, tool, arguments, result, called_at)
      when is_binary(turn_id) and is_binary(tool) and byte_size(tool) in 1..256 do
    {status, error} =
      case result do
        {:ok, _answer} -> {"completed", nil}
        {:error, error} -> {"failed", Activity.sanitize_evidence(error)}
      end

    record = %CallRecord{
      turn_id: turn_id,
      tool: tool,
      status: status,
      arguments: if(is_nil(arguments), do: nil, else: Activity.sanitize_evidence(arguments)),
      error: error,
      called_at: called_at
    }

    # A savepoint when a caller already holds a transaction, so a refused
    # write cannot abort work that is not this record's.
    _kept = Repo.transaction(fn -> Repo.insert!(record) end)
    :ok
  rescue
    _refused -> :ok
  end

  def record(_binding, _tool, _arguments, _result, _called_at), do: :ok

  @doc """
  The calls this episode's turns received at or after `since`, oldest first,
  while their turns still keep their bodies.
  """
  @spec list_for_episode(Ecto.UUID.t(), DateTime.t() | nil) :: [CallRecord.t()]
  def list_for_episode(episode_id, since \\ nil)

  def list_for_episode(episode_id, since) when is_binary(episode_id) do
    query =
      from(call in CallRecord,
        join: turn in Turn,
        on: turn.id == call.turn_id,
        where: turn.episode_id == ^episode_id and is_nil(turn.operational_pruned_at),
        order_by: [desc: call.called_at, desc: call.id],
        limit: @maximum_listed
      )

    query = if since, do: from(call in query, where: call.called_at >= ^since), else: query
    query |> Repo.all() |> Enum.reverse()
  end

  def list_for_episode(_episode_id, _since), do: []
end
