defmodule Responder.Evals.DeliveryPublisher do
  @moduledoc false

  @behaviour Responder.Delivery.Platform
  @behaviour Responder.Delivery.MessagePublisher
  @behaviour Responder.Delivery.ReactionPublisher

  alias Responder.Work.DeliveryReceipt

  @impl true
  def transport, do: "eval"

  @impl true
  def publish_message(request, agent), do: publish(:message, request, agent)

  @impl true
  def publish_reaction(request, agent), do: publish(:reaction, request, agent)

  @doc false
  def publish(kind, request, agent) when kind in [:message, :reaction] do
    message_ref = "eval-message:" <> digest(request.ref)

    with {:ok, receipt} <-
           DeliveryReceipt.new(
             request.ref,
             request.transport,
             request.conversation_ref,
             request.thread_ref,
             message_ref
           ) do
      Agent.get_and_update(agent, &publish_state(&1, kind, request, receipt))
    end
  end

  defp publish_state(
         %{deliveries: deliveries, order: order, receipts: receipts} = state,
         kind,
         request,
         receipt
       ) do
    case Map.fetch(receipts, request.ref) do
      {:ok, existing} ->
        delivery = Map.fetch!(deliveries, request.ref)
        next = put_in(state, [:deliveries, request.ref, :attempts], delivery.attempts + 1)
        {{:ok, existing}, next}

      :error ->
        store_delivery(state, kind, request, receipt, deliveries, order, receipts)
    end
  end

  defp publish_state(deliveries, kind, request, receipt) when is_list(deliveries),
    do: {{:ok, receipt}, [{kind, request, receipt} | deliveries]}

  defp digest(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
  end

  defp store_delivery(state, kind, request, receipt, deliveries, order, receipts) do
    delivery = %{attempts: 1, kind: kind, receipt: receipt, request: request}

    next = %{
      state
      | deliveries: Map.put(deliveries, request.ref, delivery),
        order: order ++ [request.ref],
        receipts: Map.put(receipts, request.ref, receipt)
    }

    if state.lose_next_response > 0 do
      {{:error, {:delivery_uncertain, :simulated_response_loss}},
       %{next | lose_next_response: state.lose_next_response - 1}}
    else
      {{:ok, receipt}, next}
    end
  end
end

defmodule Responder.Evals.SlackDeliveryPublisher do
  @moduledoc false

  @behaviour Responder.Delivery.Platform
  @behaviour Responder.Delivery.MessagePublisher
  @behaviour Responder.Delivery.ReactionPublisher

  alias Responder.Evals.DeliveryPublisher

  @impl true
  def transport, do: "slack"

  @impl true
  def publish_message(request, agent), do: DeliveryPublisher.publish(:message, request, agent)

  @impl true
  def publish_reaction(request, agent), do: DeliveryPublisher.publish(:reaction, request, agent)
end

defmodule Responder.Evals.GitHubDeliveryPublisher do
  @moduledoc false

  @behaviour Responder.Delivery.Platform
  @behaviour Responder.Delivery.MessagePublisher
  @behaviour Responder.Delivery.ReactionPublisher

  alias Responder.Evals.DeliveryPublisher

  @impl true
  def transport, do: "github"

  @impl true
  def publish_message(request, agent), do: DeliveryPublisher.publish(:message, request, agent)

  @impl true
  def publish_reaction(request, agent), do: DeliveryPublisher.publish(:reaction, request, agent)
end

defmodule Responder.Evals.LabDeliveryPublisher do
  @moduledoc false

  @behaviour Responder.Delivery.Platform
  @behaviour Responder.Delivery.MessagePublisher
  @behaviour Responder.Delivery.ReactionPublisher

  alias Responder.Evals.DeliveryPublisher

  @impl true
  def transport, do: "control_plane"

  @impl true
  def publish_message(request, agent), do: DeliveryPublisher.publish(:message, request, agent)

  @impl true
  def publish_reaction(request, agent), do: DeliveryPublisher.publish(:reaction, request, agent)
end
