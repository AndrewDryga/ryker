defmodule Ryker.Delivery.AdaptersTest do
  use ExUnit.Case, async: true

  alias Ryker.Delivery.{Adapters, Request}

  defmodule Publisher do
    @behaviour Ryker.Delivery.Platform
    @behaviour Ryker.Delivery.MessagePublisher
    @behaviour Ryker.Delivery.ReactionPublisher

    @impl true
    def transport, do: "test"

    @impl true
    def publish_message(request, binding), do: {:ok, %{binding: binding, request: request}}

    @impl true
    def publish_reaction(request, binding), do: {:ok, %{binding: binding, request: request}}
  end

  defmodule WrongPublisher do
    def transport, do: "wrong"
    def publish_message(request, binding), do: {:ok, {request, binding}}
    def publish_reaction(request, binding), do: {:ok, {request, binding}}
  end

  test "dispatches each kind only through its trusted configured publisher" do
    assert {:ok, registry} =
             Adapters.new(%{
               "test" => %{
                 binding: :trusted,
                 message_publisher: Publisher,
                 reaction_publisher: Publisher
               }
             })

    assert {:ok, message} = request(:message)
    assert {:ok, %{binding: :trusted, request: ^message}} = Adapters.publish(message, registry)

    assert {:ok, reaction} = request(:reaction)

    assert {:ok, %{binding: :trusted, request: ^reaction}} =
             Adapters.publish(reaction, registry)
  end

  test "never resolves an untrusted transport into a module" do
    assert Adapters.new(%{}) == {:error, {:invalid_delivery_adapters, :registrations}}

    assert Adapters.new(%{
             "test" => %{
               binding: nil,
               message_publisher: WrongPublisher,
               reaction_publisher: WrongPublisher
             }
           }) == {:error, {:invalid_delivery_adapters, :message}}

    assert Adapters.new(%{"test" => :invalid}) ==
             {:error, {:invalid_delivery_adapters, :registration}}

    assert Adapters.new(%{
             "test" => %{
               binding: nil,
               message_publisher: Publisher,
               reaction_publisher: WrongPublisher
             }
           }) == {:error, {:invalid_delivery_adapters, :reaction}}

    assert {:ok, registry} =
             Adapters.new(%{
               "test" => %{
                 binding: nil,
                 message_publisher: Publisher,
                 reaction_publisher: Publisher
               }
             })

    assert {:ok, unknown} =
             Request.new(%{
               conversation_ref: "unknown:conversation",
               document: %{"message" => "No module lookup."},
               kind: :message,
               ref: "delivery:unknown",
               source_item_ref: nil,
               thread_ref: nil,
               transport: "unknown"
             })

    assert Adapters.publish(unknown, registry) ==
             {:error, {:delivery_adapter_not_configured, "unknown"}}

    assert Adapters.publish(:invalid, registry) ==
             {:error, {:invalid_delivery_adapters, :request}}
  end

  defp request(:message) do
    Request.new(%{
      conversation_ref: "test:conversation",
      document: %{"message" => "Done."},
      kind: :message,
      ref: "delivery:test",
      source_item_ref: nil,
      thread_ref: nil,
      transport: "test"
    })
  end

  defp request(:reaction) do
    Request.new(%{
      conversation_ref: "test:conversation",
      document: %{"emoji_name" => "eyes"},
      kind: :reaction,
      ref: "reaction:test",
      source_item_ref: "message:test",
      thread_ref: nil,
      transport: "test"
    })
  end
end
