defmodule Responder.State.CardDelivery do
  @moduledoc """
  Whether one click came from the exact card this host delivered.

  Every offer control is authorized against the delivering turn's external
  receipt, which is the host's own record of where the card was posted. The
  receipt is trusted over the episode's bound destination because routing can
  join a new root into an existing episode and answer it in that root's own
  thread: the card then lives in a thread the episode is not bound to, and the
  press is still the press of the card we delivered. Only the conversation is
  held to the episode, because no card is ever confirmable from another channel.
  """

  alias Responder.Episodes.Episode
  alias Responder.Work.Turn

  @type target :: %{
          conversation_ref: String.t(),
          message_ref: String.t(),
          thread_ref: String.t() | nil,
          transport: String.t()
        }

  @doc """
  `:ok` when `target` is the message this settled turn's receipt was issued for.

  Callers map `:mismatch` and `:not_delivered` onto their own vocabulary so the
  refusal a person reads names the control they pressed.
  """
  @spec delivered_from?(Episode.t(), Turn.t(), target()) ::
          :ok | {:error, :mismatch | :not_delivered}
  def delivered_from?(
        %Episode{} = episode,
        %Turn{status: :settled, external_receipt: receipt},
        target
      )
      when is_map(receipt) do
    delivered = %{
      conversation_ref: receipt["conversation_ref"],
      message_ref: receipt["message_ref"],
      thread_ref: receipt["thread_ref"],
      transport: receipt["transport"]
    }

    if delivered.transport == episode.destination_transport and
         delivered.conversation_ref == episode.destination_conversation_ref and
         delivered == target,
       do: :ok,
       else: {:error, :mismatch}
  end

  def delivered_from?(_episode, _turn, _target), do: {:error, :not_delivered}
end
