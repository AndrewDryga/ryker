defmodule Ryker.Emisar.ApprovalPresenter do
  @moduledoc """
  Idempotently refreshes the original platform message for one governed run.

  The durable Work receipt fixes the transport, conversation, thread, message,
  and delivery identity. Neither the Emisar response nor model content can
  redirect the update.
  """
  alias Ryker.Delivery
  alias Ryker.Emisar.{Approval, ApprovalStatus, Review, RunState}
  alias Ryker.Episodes
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Work

  @spec publish(Approval.t(), RunState.t(), map()) :: :ok | {:error, term()}
  def publish(%Approval{} = approval, %RunState{} = state, adapters) when is_map(adapters) do
    if changed?(approval, state) do
      case source(approval) do
        {:ok, record, turn, episode} -> repaint(approval, state, adapters, record, turn, episode)
        :no_card -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  def publish(_approval, _state, _adapters),
    do: {:error, {:invalid_emisar_approval_presentation, :arguments}}

  # Whatever delivery retries, the card retries: a network blip, missing
  # credentials or Slack's own rate limit while repainting were permanent here,
  # and the task never resumed after its review (2026-10-04 review).
  @spec permanent?(term()) :: boolean()
  def permanent?({:emisar_approval_presentation_unavailable, _reason}), do: false
  def permanent?(:emisar_approval_delivery_pending), do: false
  def permanent?(reason), do: not Delivery.Retry.retryable?(reason)

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

  # The card is the message the turn that asked for the approval delivered,
  # and only that one: a repaint replaces the whole message. A turn still
  # delivering shows it soon. One that ended without a message, a silent result
  # or a turn that blocked and was retried, left no card, and the approval is
  # watched without one. That ending was refused as permanent, which stopped
  # the watch: two retried tasks waited on approvals nothing watched (episodes
  # 8e0de29c and 01a11a2f, 2026-10-08).
  defp source(approval) do
    record = Repo.peek(Records.Record.Query.by_id(approval.record_id))
    turn = record && Repo.peek(Work.Turn.Query.by_id(record.turn_id))
    episode = Repo.peek(Episodes.Episode.Query.by_id(approval.episode_id))

    case {record, turn, episode} do
      {%Records.Record{episode_id: episode_id, kind: "emisar_approval"} = record,
       %Work.Turn{episode_id: episode_id} = turn, %Episodes.Episode{id: episode_id} = episode} ->
        card(record, turn, episode)

      _invalid ->
        {:error, :emisar_approval_source_missing}
    end
  end

  defp card(record, %Work.Turn{status: :settled, external_receipt: %{}} = turn, episode),
    do: {:ok, record, turn, episode}

  defp card(_record, %Work.Turn{status: status}, _episode)
       when status in [:pending, :cancel_pending, :delivery_pending],
       do: {:error, :emisar_approval_delivery_pending}

  defp card(_record, _turn, _episode), do: :no_card

  defp repaint(approval, state, adapters, record, turn, episode) do
    with {:ok, receipt} <- Work.DeliveryReceipt.prepare(turn.external_receipt),
         :ok <- exact_receipt(turn, episode, receipt),
         true <- record.status == :open,
         {:ok, request} <- request(turn, episode),
         {:ok, statuses} <- statuses(approval, state, turn),
         :ok <-
           Delivery.Adapters.update_message(
             request,
             receipt["message_ref"],
             %{"emisar_approval_statuses" => statuses},
             adapters
           ) do
      :ok
    else
      false -> {:error, :emisar_approval_record_stale}
      {:error, reason} -> {:error, reason}
    end
  end

  # The message shows every approval its turn asked for, in the order the reply
  # showed them: this one as just seen, the others as last seen. Each update
  # drew only its own approval, so the others' cards went from the message
  # (2026-10-08).
  defp statuses(approval, state, turn) do
    refs =
      case turn.delivery_document do
        %{"outcome" => %{"record_refs" => refs}} when is_list(refs) ->
          Enum.filter(refs, &is_binary/1)

        _other ->
          []
      end

    turn.id
    |> Approval.Query.asked_by_turn(refs)
    |> Repo.all()
    |> Enum.reduce_while({:ok, []}, fn asked, {:ok, statuses} ->
      status =
        if asked.id == approval.id,
          do: ApprovalStatus.new(approval, state),
          else: ApprovalStatus.last(asked)

      case status do
        {:ok, status} -> {:cont, {:ok, statuses ++ [status]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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
    Delivery.Request.new(%{
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
