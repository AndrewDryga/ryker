defmodule Ryker.Work.DeliveryReceiptTest do
  use ExUnit.Case, async: true

  alias Ryker.Work.DeliveryReceipt

  test "a delivery receipt has one bounded transport destination and message identity" do
    assert {:ok, receipt} =
             DeliveryReceipt.new(
               "delivery:turn-1",
               "slack",
               "slack:T-blitz:C-alerts",
               "1787932000.000100",
               "1787932801.000100"
             )

    assert receipt == %{
             "delivery_ref" => "delivery:turn-1",
             "conversation_ref" => "slack:T-blitz:C-alerts",
             "message_ref" => "1787932801.000100",
             "thread_ref" => "1787932000.000100",
             "transport" => "slack"
           }

    assert byte_size(DeliveryReceipt.fingerprint(receipt)) == 64
    assert DeliveryReceipt.prepare(receipt) == {:ok, receipt}
  end

  test "empty or untyped receipts cannot settle visible work" do
    assert DeliveryReceipt.prepare(%{}) ==
             {:error, {:invalid_work_delivery_receipt, :fields}}

    assert DeliveryReceipt.new("delivery:turn-1", "slack", "C-alerts", nil, "") ==
             {:error, {:invalid_work_delivery_receipt, :message_ref}}

    assert DeliveryReceipt.prepare(:not_a_receipt) ==
             {:error, {:invalid_work_delivery_receipt, :document}}
  end

  test "a generic destination accepted by ingress can be represented exactly in its receipt" do
    conversation_ref = String.duplicate("é", 512)

    assert {:ok, receipt} =
             DeliveryReceipt.new(
               "delivery:generic:1",
               "Custom.Transport/v1",
               conversation_ref,
               "thread/обсуждение",
               "https://hooks.example/messages/one"
             )

    assert byte_size(receipt["conversation_ref"]) == 1_024
    assert receipt["transport"] == "Custom.Transport/v1"
    assert receipt["thread_ref"] == "thread/обсуждение"
  end
end
