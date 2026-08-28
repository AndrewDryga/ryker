defmodule Responder.Work.DeliveryReceipt do
  @moduledoc """
  The typed identity of one externally visible delivered message.

  Delivery gateways issue this receipt after reconciling the transport. The
  destination is intentionally opaque to Work custody, but the three-part
  identity is strict enough to prevent one external message from settling two
  delivery intents.
  """

  alias Responder.CanonicalJSON

  @fields ~w(conversation_ref delivery_ref message_ref thread_ref transport)
  @maximum_reference_bytes 1_024

  @type t :: %{String.t() => String.t()}

  @spec new(String.t(), String.t(), String.t(), String.t() | nil, String.t()) ::
          {:ok, t()} | {:error, term()}
  def new(delivery_ref, transport, conversation_ref, thread_ref, message_ref) do
    document = %{
      "conversation_ref" => conversation_ref,
      "delivery_ref" => delivery_ref,
      "message_ref" => message_ref,
      "thread_ref" => thread_ref,
      "transport" => transport
    }

    prepare(document)
  end

  @spec prepare(term()) :: {:ok, t()} | {:error, term()}
  def prepare(%{} = receipt) do
    with :ok <- exact_fields(receipt),
         :ok <- reference(receipt["delivery_ref"], :delivery_ref),
         :ok <- transport(receipt["transport"]),
         :ok <- reference(receipt["conversation_ref"], :conversation_ref),
         :ok <- optional_reference(receipt["thread_ref"], :thread_ref),
         :ok <- reference(receipt["message_ref"], :message_ref) do
      {:ok, receipt}
    end
  end

  def prepare(_receipt), do: {:error, {:invalid_work_delivery_receipt, :document}}

  @spec fingerprint(t()) :: String.t()
  def fingerprint(receipt), do: CanonicalJSON.digest(receipt)

  defp exact_fields(receipt) do
    if Map.keys(receipt) |> Enum.sort() == @fields,
      do: :ok,
      else: {:error, {:invalid_work_delivery_receipt, :fields}}
  end

  defp transport(value) do
    reference(value, :transport)
  end

  defp reference(value, field) do
    if is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
         String.trim(value) != "" and byte_size(value) <= @maximum_reference_bytes,
       do: :ok,
       else: {:error, {:invalid_work_delivery_receipt, field}}
  end

  defp optional_reference(nil, _field), do: :ok
  defp optional_reference(value, field), do: reference(value, field)
end
