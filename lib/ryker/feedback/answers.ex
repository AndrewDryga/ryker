defmodule Ryker.Feedback.Answers do
  @moduledoc """
  Which request one of Ryker's messages belongs to, when a person reacts to
  it.

  A Work reply belongs to its episode, and `Ryker.Episodes.Reactions`
  resolves it, because the reaction is also that episode's own event. The
  rest are resolved here: a quick reply routing sent by itself belongs to the
  message it answered, which has no request of its own, and an update or an
  extra post the Work model sent belongs to its episode. Only a delivered
  message, found by the receipt its platform returned, is one Ryker sent.
  """

  import Ecto.Query
  alias Ryker.Delivery.{PlatformAction, RoutingResponse}
  alias Ryker.Repo

  @type target :: %{transport: String.t(), conversation_ref: String.t(), message_ref: String.t()}

  @doc "The request of a quick reply or a posted message, or `:error` for any other message."
  @spec message_request(target()) :: {:ok, Ryker.Feedback.request()} | :error
  def message_request(%{transport: transport, conversation_ref: conversation, message_ref: ref})
      when is_binary(transport) and is_binary(conversation) and is_binary(ref) do
    case quick_reply(transport, conversation, ref) do
      input_id when is_binary(input_id) ->
        {:ok, {:input, input_id}}

      nil ->
        case post(transport, conversation, ref) do
          episode_id when is_binary(episode_id) -> {:ok, {:episode, episode_id}}
          nil -> :error
        end
    end
  end

  def message_request(_target), do: :error

  defp quick_reply(transport, conversation, ref) do
    Repo.one(
      from(response in RoutingResponse,
        where:
          response.kind == :message and response.status == :delivered and
            response.transport == ^transport and response.conversation_ref == ^conversation and
            fragment("(?::jsonb)->>'message_ref' = ?", response.external_receipt, ^ref),
        order_by: [desc: response.delivered_at, desc: response.id],
        limit: 1,
        select: response.input_id
      )
    )
  end

  defp post(transport, conversation, ref) do
    Repo.one(
      from(action in PlatformAction,
        where:
          action.kind == :message and action.status == :delivered and
            action.transport == ^transport and action.conversation_ref == ^conversation and
            fragment("(?::jsonb)->>'message_ref' = ?", action.external_receipt, ^ref),
        order_by: [desc: action.delivered_at, desc: action.id],
        limit: 1,
        select: action.episode_id
      )
    )
  end
end
