defmodule Ryker.ControlPlane.Publisher do
  @moduledoc """
  Loopback conversation delivery adapter.

  The accepted Work document already lives durably on its turn. This adapter
  adds the typed delivery receipt that settles custody; the control-plane
  projection reads the same durable turn instead of copying messages into a
  second chat store.
  """
  @behaviour Ryker.Delivery.Platform
  @behaviour Ryker.Delivery.MessagePublisher
  @behaviour Ryker.Delivery.ReactionPublisher
  alias Ryker.Crypto
  alias Ryker.Work

  @impl true
  def transport, do: "control_plane"

  @impl true
  def publish_message(request, _binding), do: receipt(request)

  # A Chat card is drawn from the durable records whenever a page reads it, so an
  # update (an Emisar approval's status, say) has no message to repaint here.
  # Refusing it was permanent and blocked every approval watch started from
  # Chat on its first poll (2026-10-04 review).
  @impl true
  def update_message(_request, _message_ref, _document, _binding), do: :ok

  @impl true
  def publish_reaction(request, _binding) do
    Work.DeliveryReceipt.new(
      request.ref,
      request.transport,
      request.conversation_ref,
      request.thread_ref,
      request.source_item_ref
    )
  end

  defp receipt(request) do
    Work.DeliveryReceipt.new(
      request.ref,
      request.transport,
      request.conversation_ref,
      request.thread_ref,
      "control-plane-message:#{digest(request.ref)}"
    )
  end

  defp digest(value) do
    Crypto.sha256_hex(value)
    |> binary_part(0, 24)
  end
end
