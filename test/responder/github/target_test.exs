defmodule Responder.GitHub.TargetTest do
  use ExUnit.Case, async: true

  alias Responder.Delivery.Request
  alias Responder.GitHub.Target

  test "rejects malformed repository, thread, and reaction identities" do
    invalid = [
      request(:message, "github:Bad:repository:99", "github:Bad:pull:42", nil),
      request(:message, "github:main:repository:nope", "github:main:pull:42", nil),
      request(:message, "github:main:repository:99", "github:main:pull:nope", nil),
      request(
        :message,
        "github:main:repository:99",
        "github:main:pull:42:review-thread:nope",
        nil
      ),
      request(:message, "github:main:repository:99", "github:other:pull:42", nil),
      request(
        :reaction,
        "github:main:repository:99",
        "github:main:pull:42",
        "github:issue_comment:nope"
      ),
      request(
        :reaction,
        "github:main:repository:99",
        "github:main:pull:42",
        "github:pull_request_review:42"
      ),
      %{
        request(:message, "github:main:repository:99", "github:main:pull:42", nil)
        | source_item_ref: "unexpected"
      }
    ]

    Enum.each(invalid, fn request ->
      assert {:error, {:invalid_github_delivery_target, _field}} = Target.parse(request)
    end)

    slack = %{request(:message, "slack:T:C", "thread", nil) | transport: "slack"}
    assert Target.parse(slack) == {:error, {:invalid_github_delivery_target, :transport}}
  end

  defp request(kind, conversation_ref, thread_ref, source_item_ref) do
    assert {:ok, request} =
             Request.new(%{
               conversation_ref: conversation_ref,
               document: document(kind),
               kind: kind,
               ref: "delivery:target:#{System.unique_integer([:positive])}",
               source_item_ref: source_item_ref,
               thread_ref: thread_ref,
               transport: "github"
             })

    request
  end

  defp document(:message), do: %{"message" => "Done."}
  defp document(:reaction), do: %{"emoji_name" => "eyes"}
end
