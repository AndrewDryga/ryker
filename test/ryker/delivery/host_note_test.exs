defmodule Ryker.Delivery.HostNoteTest do
  use ExUnit.Case, async: true

  alias Ryker.Delivery.{Adapters, HostNote}

  defmodule Refusing do
    @behaviour Ryker.Delivery.Platform
    @behaviour Ryker.Delivery.MessagePublisher
    @behaviour Ryker.Delivery.ReactionPublisher

    def transport, do: "control_plane"

    def publish_message(_request, test) do
      send(test, :published)
      {:error, :not_used}
    end

    def publish_reaction(_request, _test), do: {:error, :not_used}
  end

  # A note is the host's own sentence in the conversation and thread its
  # caller names, under the caller's fixed delivery ref: a retry finds the
  # post it already made instead of adding a second one.
  test "a note is the host's words, where its caller says, under one fixed ref" do
    assert {:ok, request} = HostNote.request(note())
    assert request.kind == :message
    assert request.document == %{"message" => "The incident room #ems-checkout was deleted."}
    assert request.ref == "incident-room:one:deleted"
    assert request.transport == "slack"
    assert request.conversation_ref == "slack:T1:C1"
    assert request.thread_ref == "1787832000.000100"
    assert {:ok, ^request} = HostNote.request(note())
  end

  # Nobody reads a shadow conversation, and one Ryker has no publisher for
  # cannot be told anything: neither may hold its caller open retrying.
  test "a note nobody could receive comes back not posted, with the reason" do
    {:ok, adapters} =
      Adapters.new(%{
        "control_plane" => %{
          binding: self(),
          message_publisher: Refusing,
          reaction_publisher: Refusing
        }
      })

    assert {:ok, {:not_posted, :shadow}} =
             HostNote.deliver(%{note() | execution_mode: :shadow}, adapters)

    assert {:ok, {:not_posted, {:delivery_adapter_not_configured, "slack"}}} =
             HostNote.deliver(note(), adapters)

    assert {:ok, {:not_posted, :delivery_not_configured}} = HostNote.deliver(note(), nil)

    refute_received :published
  end

  defp note do
    %HostNote{
      conversation_ref: "slack:T1:C1",
      execution_mode: :live,
      message: "The incident room #ems-checkout was deleted.",
      ref: "incident-room:one:deleted",
      thread_ref: "1787832000.000100",
      transport: "slack"
    }
  end
end
