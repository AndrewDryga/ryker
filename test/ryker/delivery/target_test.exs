defmodule Ryker.Delivery.TargetTest do
  use ExUnit.Case, async: true

  alias Ryker.Delivery.Request
  alias Ryker.GitHub.Target, as: GitHubTarget
  alias Ryker.Slack.Target, as: SlackTarget

  test "Slack targets derive workspace, channel, thread, and reaction item from host refs" do
    assert {:ok, request} =
             Request.new(%{
               conversation_ref: "slack:T123:C456",
               document: %{"emoji_name" => "eyes"},
               kind: :reaction,
               ref: "reaction:1",
               source_item_ref: "1787832001.000200",
               thread_ref: "1787832000.000100",
               transport: "slack"
             })

    assert {:ok,
            %{
              channel_ref: "C456",
              message_ref: "1787832001.000200",
              thread_ref: "1787832000.000100",
              workspace_ref: "T123"
            }} = SlackTarget.parse(request)

    assert {:ok, message} =
             Request.new(%{
               conversation_ref: "slack:T123:C456",
               document: %{"message" => "Done."},
               kind: :message,
               ref: "delivery:slack",
               source_item_ref: nil,
               thread_ref: nil,
               transport: "slack"
             })

    assert {:ok, %{message_ref: nil, thread_ref: nil}} = SlackTarget.parse(message)
  end

  test "GitHub targets retain a pull number for inline review replies" do
    assert {:ok, request} =
             Request.new(%{
               conversation_ref: "github:github-main:repository:99",
               document: %{"message" => "Fixed."},
               kind: :message,
               ref: "delivery:1",
               source_item_ref: nil,
               thread_ref: "github:github-main:pull:42:review-thread:8001",
               transport: "github"
             })

    assert {:ok,
            %{
              binding: "github-main",
              repository_id: 99,
              source_item: nil,
              thread: %{kind: "review_thread", number: 42, review_root_id: 8001}
            }} = GitHubTarget.parse(request)

    assert {:ok, issue} =
             Request.new(%{
               conversation_ref: "github:github-main:repository:99",
               document: %{"message" => "Fixed."},
               kind: :message,
               ref: "delivery:issue",
               source_item_ref: nil,
               thread_ref: "github:github-main:issue:7",
               transport: "github"
             })

    assert {:ok, %{thread: %{kind: "issue", number: 7}}} = GitHubTarget.parse(issue)
  end

  test "GitHub reactions preserve the exact supported comment kind" do
    for {kind, id} <- [{"issue_comment", 9001}, {"pull_request_review_comment", 8002}] do
      assert {:ok, request} =
               Request.new(%{
                 conversation_ref: "github:github-main:repository:99",
                 document: %{"emoji_name" => "heart"},
                 kind: :reaction,
                 ref: "reaction:#{id}",
                 source_item_ref: "github:#{kind}:#{id}",
                 thread_ref: "github:github-main:pull:42",
                 transport: "github"
               })

      assert {:ok, %{source_item: %{id: ^id, kind: ^kind}}} = GitHubTarget.parse(request)
    end
  end

  test "platform parsers reject crossed binding and malformed native targets" do
    assert {:ok, crossed} =
             Request.new(%{
               conversation_ref: "github:github-main:repository:99",
               document: %{"message" => "No."},
               kind: :message,
               ref: "delivery:crossed",
               source_item_ref: nil,
               thread_ref: "github:other:pull:42",
               transport: "github"
             })

    assert GitHubTarget.parse(crossed) ==
             {:error, {:invalid_github_delivery_target, :thread_ref}}

    assert {:ok, malformed_slack} =
             Request.new(%{
               conversation_ref: "slack:T123:C456",
               document: %{"emoji_name" => "eyes"},
               kind: :reaction,
               ref: "reaction:bad",
               source_item_ref: "not-a-timestamp",
               thread_ref: nil,
               transport: "slack"
             })

    assert SlackTarget.parse(malformed_slack) ==
             {:error, {:invalid_slack_delivery_target, :source_item_ref}}

    assert {:ok, bad_thread} =
             Request.new(%{
               conversation_ref: "slack:T123:C456",
               document: %{"message" => "No."},
               kind: :message,
               ref: "delivery:bad-thread",
               source_item_ref: nil,
               thread_ref: "bad-thread",
               transport: "slack"
             })

    assert SlackTarget.parse(bad_thread) ==
             {:error, {:invalid_slack_delivery_target, :thread_ref}}

    assert GitHubTarget.parse(%{crossed | transport: "slack"}) ==
             {:error, {:invalid_github_delivery_target, :transport}}

    assert SlackTarget.parse(%{malformed_slack | transport: "github"}) ==
             {:error, {:invalid_slack_delivery_target, :transport}}
  end
end
