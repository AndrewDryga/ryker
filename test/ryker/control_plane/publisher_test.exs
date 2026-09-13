defmodule Ryker.ControlPlane.PublisherTest do
  use ExUnit.Case, async: true

  alias Ryker.ControlPlane.Publisher
  alias Ryker.Delivery.Request

  test "local conversations settle through a typed deterministic delivery receipt" do
    assert {:ok, request} =
             Request.new(%{
               conversation_ref: "control-plane:lab:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
               document: %{"message" => "A real Work reply."},
               kind: :message,
               ref: "delivery:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
               source_item_ref: nil,
               thread_ref: "control-plane:lab:018f3ef7-1f62-7ee0-a83c-0c12f21d83e6",
               transport: "control_plane"
             })

    assert {:ok, receipt} = Publisher.publish_message(request, nil)
    assert receipt["delivery_ref"] == request.ref
    assert receipt["transport"] == "control_plane"
    assert receipt["conversation_ref"] == request.conversation_ref
    assert receipt["thread_ref"] == request.thread_ref
    assert receipt["message_ref"] =~ ~r/\Acontrol-plane-message:[0-9a-f]{24}\z/

    assert Publisher.publish_message(request, nil) == {:ok, receipt}
  end
end
