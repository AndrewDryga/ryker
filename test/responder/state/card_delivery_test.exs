defmodule Responder.State.CardDeliveryTest do
  use ExUnit.Case, async: true

  alias Responder.Episodes.Episode
  alias Responder.State.CardDelivery
  alias Responder.Work.Turn

  @home_thread "1789004000.000100"
  @origin_thread "1789004500.000700"
  @message "1789004501.000200"

  test "a card is confirmable from the thread its episode is bound to" do
    episode = episode()
    turn = settled(@home_thread)

    assert CardDelivery.delivered_from?(episode, turn, target(@home_thread, @message)) == :ok
  end

  test "a card is confirmable from the origin thread routing delivered it to" do
    # Found live 2026-09-11: routing delivered a correction card to the joined
    # root's thread and the Save press was refused as "no longer current"; a
    # human sees the same.
    episode = episode()
    turn = settled(@origin_thread)

    assert CardDelivery.delivered_from?(episode, turn, target(@origin_thread, @message)) == :ok
  end

  test "a card is not confirmable from a thread it was never delivered to" do
    episode = episode()
    turn = settled(@origin_thread)

    assert CardDelivery.delivered_from?(episode, turn, target(@home_thread, @message)) ==
             {:error, :mismatch}
  end

  test "a card is not confirmable through another message in its own thread" do
    episode = episode()
    turn = settled(@origin_thread)

    assert CardDelivery.delivered_from?(
             episode,
             turn,
             target(@origin_thread, "1789004509.000900")
           ) == {:error, :mismatch}
  end

  test "a card delivered to another conversation is confirmable from neither" do
    # The receipt is trusted for the thread, never for the channel: an episode
    # can only ever authorize controls in the conversation it belongs to.
    episode = episode()
    turn = settled(@origin_thread, "slack:T123:C999")

    assert CardDelivery.delivered_from?(
             episode,
             turn,
             target(@origin_thread, @message, "slack:T123:C999")
           ) == {:error, :mismatch}

    assert CardDelivery.delivered_from?(episode, turn, target(@origin_thread, @message)) ==
             {:error, :mismatch}
  end

  test "a card nothing has delivered yet carries no confirmable location" do
    episode = episode()
    target = target(@home_thread, @message)

    assert CardDelivery.delivered_from?(episode, %Turn{status: :pending}, target) ==
             {:error, :not_delivered}

    assert CardDelivery.delivered_from?(
             episode,
             %{settled(@home_thread) | external_receipt: nil},
             target
           ) == {:error, :not_delivered}

    assert CardDelivery.delivered_from?(
             episode,
             %{settled(@home_thread) | status: :pending},
             target
           ) == {:error, :not_delivered}
  end

  defp episode do
    %Episode{
      destination_transport: "slack",
      destination_conversation_ref: "slack:T123:C456",
      destination_thread_ref: @home_thread
    }
  end

  defp settled(thread_ref, conversation_ref \\ "slack:T123:C456") do
    %Turn{
      status: :settled,
      external_receipt: %{
        "conversation_ref" => conversation_ref,
        "delivery_ref" => "delivery:card",
        "message_ref" => @message,
        "thread_ref" => thread_ref,
        "transport" => "slack"
      }
    }
  end

  defp target(thread_ref, message_ref, conversation_ref \\ "slack:T123:C456") do
    %{
      conversation_ref: conversation_ref,
      message_ref: message_ref,
      thread_ref: thread_ref,
      transport: "slack"
    }
  end
end
