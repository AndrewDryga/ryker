defmodule Ryker.Delivery.Operator do
  @moduledoc """
  Trusted inspection and rearm surface for blocked delivery custody.

  It exposes only routing identifiers, retry state, and bounded error detail;
  frozen model output and platform credentials never cross this boundary.
  """

  import Ecto.Query

  alias Ryker.Delivery.{PlatformAction, PlatformActionCustody, Reaction, ReactionCustody}
  alias Ryker.Repo
  alias Ryker.Work.{Custody, Turn}

  @maximum_list 500

  @spec list_blocked(pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def list_blocked(limit \\ 100) do
    if is_integer(limit) and limit > 0 and limit <= @maximum_list do
      messages =
        Repo.all(
          from(turn in Turn,
            where: turn.status == :blocked and not is_nil(turn.delivery_ref),
            order_by: [asc: turn.updated_at, asc: turn.id],
            limit: ^limit
          )
        )

      reactions =
        Repo.all(
          from(reaction in Reaction,
            where: reaction.status == :blocked,
            order_by: [asc: reaction.updated_at, asc: reaction.id],
            limit: ^limit
          )
        )

      actions =
        Repo.all(
          from(action in PlatformAction,
            where: action.status == :blocked,
            order_by: [asc: action.updated_at, asc: action.id],
            limit: ^limit
          )
        )

      items =
        (Enum.map(messages, &message_item/1) ++
           Enum.map(reactions, &reaction_item/1) ++ Enum.map(actions, &action_item/1))
        |> Enum.sort_by(&{DateTime.to_unix(&1.updated_at, :microsecond), &1.delivery_ref})
        |> Enum.take(limit)

      {:ok, items}
    else
      {:error, {:invalid_delivery_operator, :limit}}
    end
  end

  @spec fetch(String.t()) :: {:ok, map()} | {:error, term()}
  def fetch(delivery_ref) do
    with :ok <- reference(delivery_ref),
         {:ok, {_kind, record}} <- lookup(delivery_ref) do
      {:ok, item(record)}
    end
  end

  @spec rearm(String.t()) :: {:ok, map()} | {:error, term()}
  def rearm(delivery_ref) do
    with :ok <- reference(delivery_ref),
         {:ok, target} <- lookup(delivery_ref),
         {:ok, record} <- rearm_target(target) do
      {:ok, item(record)}
    end
  end

  defp lookup(delivery_ref) do
    message = Repo.get_by(Turn, delivery_ref: delivery_ref)
    reaction = Repo.get_by(Reaction, delivery_ref: delivery_ref)
    action = Repo.get_by(PlatformAction, action_ref: delivery_ref)

    case {message, reaction, action} do
      {%Turn{} = turn, nil, nil} -> {:ok, {:message, turn}}
      {nil, %Reaction{} = reaction, nil} -> {:ok, {:reaction, reaction}}
      {nil, nil, %PlatformAction{} = action} -> {:ok, {:action, action}}
      {nil, nil, nil} -> {:error, :delivery_not_found}
      _ambiguous -> {:error, :delivery_ref_ambiguous}
    end
  end

  defp rearm_target({:message, turn}) do
    Custody.retry_delivery(turn.episode_id, turn.turn_ref, turn.delivery_ref)
  end

  defp rearm_target({:reaction, reaction}), do: ReactionCustody.retry(reaction.delivery_ref)
  defp rearm_target({:action, action}), do: PlatformActionCustody.retry(action.action_ref)

  defp item(%Turn{} = turn), do: message_item(turn)
  defp item(%Reaction{} = reaction), do: reaction_item(reaction)
  defp item(%PlatformAction{} = action), do: action_item(action)

  defp message_item(turn) do
    %{
      attempt_count: turn.delivery_attempt_count,
      delivery_ref: turn.delivery_ref,
      episode_id: turn.episode_id,
      error_code: turn.last_error_code,
      error_detail: turn.last_error_detail,
      kind: :message,
      retry_generation: turn.delivery_retry_generation,
      status: turn.status,
      turn_ref: turn.turn_ref,
      updated_at: turn.updated_at
    }
  end

  defp reaction_item(reaction) do
    %{
      attempt_count: reaction.attempt_count,
      delivery_ref: reaction.delivery_ref,
      error_code: reaction.last_error_code,
      error_detail: reaction.last_error_detail,
      input_id: reaction.input_id,
      kind: :reaction,
      retry_generation: reaction.retry_generation,
      status: reaction.status,
      updated_at: reaction.updated_at
    }
  end

  defp action_item(action) do
    %{
      attempt_count: action.attempt_count,
      delivery_ref: action.action_ref,
      episode_id: action.episode_id,
      error_code: action.last_error_code,
      error_detail: action.last_error_detail,
      kind: :platform_action,
      retry_generation: action.retry_generation,
      status: action.status,
      tool: action.tool,
      turn_id: action.turn_id,
      updated_at: action.updated_at
    }
  end

  defp reference(value) do
    if is_binary(value) and String.valid?(value) and String.trim(value) != "" and
         :binary.match(value, <<0>>) == :nomatch and byte_size(value) <= 1_024,
       do: :ok,
       else: {:error, {:invalid_delivery_operator, :delivery_ref}}
  end
end
