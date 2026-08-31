defmodule Responder.ControlPlane.Publisher do
  @moduledoc """
  Loopback conversation delivery adapter.

  The accepted Work document already lives durably on its turn. This adapter
  adds the typed delivery receipt that settles custody; the control-plane
  projection reads the same durable turn instead of copying messages into a
  second chat store.
  """

  @behaviour Responder.Delivery.Platform
  @behaviour Responder.Delivery.MessagePublisher
  @behaviour Responder.Delivery.ReactionPublisher

  alias Responder.Work.DeliveryReceipt

  @impl true
  def transport, do: "control_plane"

  @impl true
  def publish_message(request, _binding), do: receipt(request)

  @impl true
  def publish_reaction(request, _binding), do: receipt(request)

  defp receipt(request) do
    DeliveryReceipt.new(
      request.ref,
      request.transport,
      request.conversation_ref,
      request.thread_ref,
      "control-plane-message:#{digest(request.ref)}"
    )
  end

  defp digest(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 24)
  end
end
