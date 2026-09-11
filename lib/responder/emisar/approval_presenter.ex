defmodule Responder.Emisar.ApprovalPresenter do
  @moduledoc """
  Idempotently refreshes the original platform message for one governed run.

  The durable Work receipt fixes the transport, conversation, thread, message,
  and delivery identity. Neither the Emisar response nor model content can
  redirect the update.
  """

  alias Responder.Delivery.{Adapters, Request}
  alias Responder.Emisar.{Approval, ApprovalStatus, Review, RunState}
  alias Responder.Episodes.Episode
  alias Responder.Repo
  alias Responder.State.Record
  alias Responder.Work.{DeliveryReceipt, Turn}

  @spec publish(Approval.t(), RunState.t(), map()) :: :ok | {:error, term()}
  def publish(%Approval{} = approval, %RunState{} = state, adapters) when is_map(adapters) do
    if changed?(approval, state) do
      with {:ok, record, turn, episode} <- source(approval),
           {:ok, receipt} <- DeliveryReceipt.prepare(turn.external_receipt),
           :ok <- exact_receipt(turn, episode, receipt),
           true <- record.status == :open,
           {:ok, request} <- request(turn, episode),
           {:ok, status} <- ApprovalStatus.new(approval, state),
           :ok <-
             Adapters.update_message(
               request,
               receipt["message_ref"],
               %{"emisar_approval_status" => status},
               adapters
             ) do
        :ok
      else
        false -> {:error, :emisar_approval_record_stale}
        {:error, _reason} = error -> error
      end
    else
      :ok
    end
  end

  def publish(_approval, _state, _adapters),
    do: {:error, {:invalid_emisar_approval_presentation, :arguments}}

  @spec permanent?(term()) :: boolean()
  def permanent?({:delivery_rate_limited, _delay, _reason}), do: false
  def permanent?({:delivery_uncertain, _reason}), do: false
  def permanent?({:slack_http_error, status, _detail}) when status >= 500, do: false
  def permanent?({:github_api_error, status, _detail}) when status >= 500, do: false
  def permanent?({:emisar_approval_presentation_unavailable, _reason}), do: false
  def permanent?(_reason), do: true

  # A repaint costs an operator's attention, so it follows a change this card can
  # actually show. The card reports the REVIEW: a second reviewer arriving, a
  # denial, or an override moves nothing in the remote run status, which sits at
  # `pending_approval` throughout — and once the review is decided, the run's own
  # march through sent, running and success changes nothing on it. Execution
  # belongs to the episode, not to a stream of repaints of a settled decision.
  # A run carrying no receipt at all still tracks its status, which is then the
  # only thing the card states.
  defp changed?(approval, state) do
    approval.review_digest != Review.digest(state.review) or
      approval.run_url != state.run_url or
      approval.remote_error != state.error_message or
      (is_nil(state.review) and approval.remote_status != state.status)
  end

  defp source(approval) do
    record = Repo.get(Record, approval.record_id)
    turn = record && Repo.get(Turn, record.turn_id)
    episode = Repo.get(Episode, approval.episode_id)

    case {record, turn, episode} do
      {%Record{episode_id: episode_id, kind: "emisar_approval"} = record,
       %Turn{episode_id: episode_id, status: :settled} = turn, %Episode{id: episode_id} = episode} ->
        {:ok, record, turn, episode}

      _invalid ->
        {:error, :emisar_approval_delivery_not_settled}
    end
  end

  defp exact_receipt(turn, episode, receipt) do
    exact =
      receipt["delivery_ref"] == turn.delivery_ref and
        receipt["transport"] == episode.destination_transport and
        receipt["conversation_ref"] == episode.destination_conversation_ref and
        receipt["thread_ref"] == episode.destination_thread_ref

    if exact, do: :ok, else: {:error, :emisar_approval_delivery_receipt_mismatch}
  end

  defp request(turn, episode) do
    Request.new(%{
      conversation_ref: episode.destination_conversation_ref,
      document: %{"message" => "Host-owned governed action status."},
      kind: :message,
      ref: turn.delivery_ref,
      source_item_ref: nil,
      thread_ref: episode.destination_thread_ref,
      transport: episode.destination_transport
    })
  end
end
