defmodule Ryker.Records.CardDeliveryTest do
  use ExUnit.Case, async: true
  alias Ryker.Episodes.Episode
  alias Ryker.Records.CardDelivery
  alias Ryker.Work.Turn

  @home_thread "1789004000.000100"
  @origin_thread "1789004500.000700"
  @message "1789004501.000200"

  setup do
    %{episode: episode()}
  end

  test "a card is confirmable from the thread its episode is bound to", %{episode: episode} do
    turn = settled(@home_thread)

    assert CardDelivery.check(episode, turn, target(@home_thread, @message)) == :ok
  end

  test "a card is confirmable from the origin thread routing delivered it to", %{episode: episode} do
    # Found live 2026-09-11: routing delivered a correction card to the joined
    # root's thread and the Save press was refused as "no longer current"; a
    # human sees the same.
    turn = settled(@origin_thread)

    assert CardDelivery.check(episode, turn, target(@origin_thread, @message)) == :ok
  end

  test "a card is not confirmable from a thread it was never delivered to", %{episode: episode} do
    turn = settled(@origin_thread)

    assert CardDelivery.check(episode, turn, target(@home_thread, @message)) ==
             {:error, :mismatch}
  end

  test "a card is not confirmable through another message in its own thread", %{episode: episode} do
    turn = settled(@origin_thread)

    assert CardDelivery.check(
             episode,
             turn,
             target(@origin_thread, "1789004509.000900")
           ) == {:error, :mismatch}
  end

  test "a card delivered to another conversation is confirmable from neither", %{episode: episode} do
    # The receipt is trusted for the thread, never for the channel: an episode
    # can only ever authorize controls in the conversation it belongs to.
    turn = settled(@origin_thread, "slack:T123:C999")

    assert CardDelivery.check(
             episode,
             turn,
             target(@origin_thread, @message, "slack:T123:C999")
           ) == {:error, :mismatch}

    assert CardDelivery.check(episode, turn, target(@origin_thread, @message)) ==
             {:error, :mismatch}
  end

  test "a card nothing has delivered yet carries no confirmable location", %{episode: episode} do
    target = target(@home_thread, @message)

    assert CardDelivery.check(episode, %Turn{status: :pending}, target) ==
             {:error, :not_delivered}

    assert CardDelivery.check(
             episode,
             %{settled(@home_thread) | external_receipt: nil},
             target
           ) == {:error, :not_delivered}

    assert CardDelivery.check(
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
