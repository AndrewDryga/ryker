defmodule Ryker.Delivery.ReconciledMessage do
  @moduledoc "Create or update one marked message, including recovery after a lost create response."
  alias Ryker.CanonicalJSON
  alias Ryker.Delivery.Adapters
  alias Ryker.Work

  def publish(request, nil, _fingerprint, adapters) do
    with {:ok, receipt} <- Adapters.publish(request, adapters),
         :ok <- validate(request, receipt),
         # A reconciled message can contain the previous projection.
         :ok <-
           Adapters.update_message(request, receipt["message_ref"], request.document, adapters),
         do: {:ok, receipt}
  end

  def publish(request, receipt, fingerprint, adapters) do
    with :ok <- validate(request, receipt),
         :ok <- update_changed(request, receipt, fingerprint, adapters),
         do: {:ok, receipt}
  end

  defp update_changed(request, receipt, fingerprint, adapters) do
    if fingerprint == CanonicalJSON.digest(request.document) do
      :ok
    else
      Adapters.update_message(request, receipt["message_ref"], request.document, adapters)
    end
  end

  def validate(request, receipt) do
    with {:ok, ^receipt} <- Work.DeliveryReceipt.prepare(receipt),
         true <-
           receipt["delivery_ref"] == request.ref and receipt["transport"] == request.transport and
             receipt["conversation_ref"] == request.conversation_ref and
             receipt["thread_ref"] == request.thread_ref,
         do: :ok,
         else: (_invalid -> {:error, :message_receipt_mismatch})
  end
end
