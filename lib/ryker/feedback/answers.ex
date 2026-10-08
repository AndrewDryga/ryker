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
  alias Ryker.Delivery
  alias Ryker.Repo

  @type target :: %{transport: String.t(), conversation_ref: String.t(), message_ref: String.t()}

  @doc "The request of a quick reply or a posted message, or `:error` for any other message."
  @spec message_request(target()) :: {:ok, Ryker.Feedback.request()} | :error
  def message_request(%{transport: transport, conversation_ref: conversation, message_ref: ref})
      when is_binary(transport) and is_binary(conversation) and is_binary(ref) do
    case quick_reply(transport, conversation, ref) do
      {:ok, input_id} when is_binary(input_id) ->
        {:ok, {:input, input_id}}

      {:error, :not_found} ->
        case post(transport, conversation, ref) do
          {:ok, episode_id} when is_binary(episode_id) -> {:ok, {:episode, episode_id}}
          {:error, :not_found} -> :error
        end
    end
  end

  def message_request(_target), do: :error

  defp quick_reply(transport, conversation, ref) do
    Delivery.RoutingResponse.Query.delivered_messages()
    |> Delivery.RoutingResponse.Query.by_conversation(transport, conversation)
    |> Delivery.RoutingResponse.Query.by_receipt_message(ref)
    |> Delivery.RoutingResponse.Query.ordered_by_delivered_at_desc()
    |> Delivery.RoutingResponse.Query.limit_to(1)
    |> Delivery.RoutingResponse.Query.select_input_ids()
    |> Repo.fetch()
  end

  defp post(transport, conversation, ref) do
    Delivery.PlatformAction.Query.delivered_messages()
    |> Delivery.PlatformAction.Query.by_conversation(transport, conversation)
    |> Delivery.PlatformAction.Query.by_receipt_message(ref)
    |> Delivery.PlatformAction.Query.ordered_by_delivered_at_desc()
    |> Delivery.PlatformAction.Query.limit_to(1)
    |> Delivery.PlatformAction.Query.select_episode_ids()
    |> Repo.fetch()
  end
end
