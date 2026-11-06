defmodule Ryker.GitHub.ReviewReplyTest do
  use ExUnit.Case, async: true
  alias Ryker.GitHub.{Binding, ReviewReply}

  defmodule Requester do
    def request({test, response}, :get, path, nil, _headers) do
      send(test, {:requested, path})
      response
    end
  end

  # Harvested parent metadata from a missed review reply on 2026-11-06;
  # repository, comment and actor identities are pseudonymized.
  @parent %{
    "id" => 7001,
    "pull_request_url" => "https://api.github.com/repos/acme/widget/pulls/42",
    "user" => %{"id" => 4321, "type" => "Bot"}
  }
  @payload %{"comment" => %{"in_reply_to_id" => 7001}, "pull_request" => %{"number" => 42}}

  test "only this App's parent on the same pull request addresses Ryker" do
    assert check(@parent) == {:ok, true}
    assert_received {:requested, "/repos/acme/widget/pulls/comments/7001"}

    for parent <- [
          put_in(@parent["id"], 7002),
          put_in(@parent["user"]["id"], 4322),
          put_in(@parent["user"]["type"], "User"),
          put_in(
            @parent["pull_request_url"],
            "https://api.github.com/repos/acme/widget/pulls/43"
          ),
          %{}
        ] do
      assert check(parent) == {:ok, false}
    end
  end

  test "missing parents do not address Ryker; failed lookups remain retryable" do
    assert request({:ok, %{status: 404}}) == {:ok, false}

    assert request({:ok, %{status: 503}}) ==
             {:error, {:github_review_reply_unavailable, {:http_status, 503}}}

    assert request({:error, :timeout}) == {:error, {:github_review_reply_unavailable, :timeout}}
  end

  test "invalid parent identifiers never make an API request" do
    for id <- [nil, "7001", -1, 0] do
      assert ReviewReply.check(binding!(), put_in(@payload["comment"]["in_reply_to_id"], id), nil,
               requester: Requester
             ) == {:ok, false}

      refute_received {:requested, _}
    end
  end

  defp check(parent), do: request({:ok, %{status: 200, body: parent}})

  defp request(response),
    do: ReviewReply.check(binding!(), @payload, {self(), response}, requester: Requester)

  defp binding! do
    {:ok, binding} =
      Binding.new(
        name: "widget",
        repository_full_name: "acme/widget",
        repository_id: 99,
        installation_id: 41,
        ryker_actor_id: 4321
      )

    binding
  end
end
