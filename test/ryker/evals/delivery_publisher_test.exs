defmodule Ryker.Evals.DeliveryPublisherTest do
  use ExUnit.Case, async: true

  alias Ryker.Delivery.Request

  alias Ryker.Evals.{
    DeliveryPublisher,
    GitHubDeliveryPublisher,
    SlackDeliveryPublisher
  }

  test "evaluation delivery adapters exercise the exact platform interface without external writes" do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{deliveries: %{}, lose_next_response: 0, order: [], receipts: %{}}
      end)

    on_exit(fn ->
      if Process.alive?(agent), do: Agent.stop(agent)
    end)

    assert DeliveryPublisher.transport() == "eval"
    assert SlackDeliveryPublisher.transport() == "slack"
    assert GitHubDeliveryPublisher.transport() == "github"

    assert {:ok, slack_message} = message_request("slack", "delivery:slack:message")
    assert {:ok, slack_reaction} = reaction_request("slack", "delivery:slack:reaction")
    assert {:ok, github_message} = message_request("github", "delivery:github:message")
    assert {:ok, github_reaction} = reaction_request("github", "delivery:github:reaction")
    assert {:ok, eval_message} = message_request("eval", "delivery:eval:message")
    assert {:ok, eval_reaction} = reaction_request("eval", "delivery:eval:reaction")

    assert {:ok, _receipt} = SlackDeliveryPublisher.publish_message(slack_message, agent)
    assert {:ok, _receipt} = SlackDeliveryPublisher.publish_reaction(slack_reaction, agent)
    assert {:ok, _receipt} = GitHubDeliveryPublisher.publish_message(github_message, agent)
    assert {:ok, _receipt} = GitHubDeliveryPublisher.publish_reaction(github_reaction, agent)
    assert {:ok, _receipt} = DeliveryPublisher.publish_message(eval_message, agent)
    assert {:ok, _receipt} = DeliveryPublisher.publish_reaction(eval_reaction, agent)

    assert Agent.get(agent, &Enum.map(&1.order, fn ref -> &1.deliveries[ref].kind end)) == [
             :message,
             :reaction,
             :message,
             :reaction,
             :message,
             :reaction
           ]
  end

  defp message_request(transport, ref) do
    Request.new(%{
      conversation_ref: "#{transport}:conversation:1",
      document: %{"message" => "Evaluation output"},
      kind: :message,
      ref: ref,
      source_item_ref: nil,
      thread_ref: "thread:1",
      transport: transport
    })
  end

  defp reaction_request(transport, ref) do
    Request.new(%{
      conversation_ref: "#{transport}:conversation:1",
      document: %{"emoji_name" => "eyes"},
      kind: :reaction,
      ref: ref,
      source_item_ref: "message:1",
      thread_ref: "thread:1",
      transport: transport
    })
  end
end
