defmodule Ryker.GitHub.RequestFeedbackTest do
  use ExUnit.Case, async: true
  alias Ryker.GitHub.{Client, Input, RequestFeedback}
  alias Ryker.TestSupport.GitHubRequester

  test "a lost acknowledgment is found in the original discussion before retrying" do
    {binding, input} = request()

    {:ok, requester} =
      GitHubRequester.start([
        response(200, []),
        response(201, %{"id" => 701})
      ])

    {:ok, client} =
      Client.new(
        http: requester,
        requester: GitHubRequester,
        ryker_actor_id: binding.ryker_actor_id
      )

    assert RequestFeedback.deliver(binding, input, {:denied, :write}, client) == :ok

    [_, {:post, "/repos/octo/example/issues/42/comments", %{"body" => body}, _}] =
      GitHubRequester.requests(requester)

    assert body =~ "Write access"
    assert body =~ "<!-- ryker-delivery:"

    {:ok, retry_requester} =
      GitHubRequester.start([
        response(200, [
          %{"id" => 701, "body" => body, "user" => %{"id" => binding.ryker_actor_id}}
        ])
      ])

    {:ok, retry_client} =
      Client.new(
        http: retry_requester,
        requester: GitHubRequester,
        ryker_actor_id: binding.ryker_actor_id
      )

    assert RequestFeedback.deliver(binding, input, {:denied, :write}, retry_client) == :ok
    assert [{:get, _, nil, _}] = GitHubRequester.requests(retry_requester)
  end

  test "confirmation outcomes explain success, repetition, and an unavailable offer" do
    {binding, input} = request()

    for {status, words} <- [
          {"confirmed", "Confirmed."},
          {"duplicate", "already confirmed"},
          {"invalid", "exact command"}
        ] do
      {:ok, requester} = GitHubRequester.start([response(200, []), response(201, %{"id" => 701})])

      {:ok, client} =
        Client.new(
          http: requester,
          requester: GitHubRequester,
          ryker_actor_id: binding.ryker_actor_id
        )

      assert RequestFeedback.deliver(binding, input, {:confirmation, status}, client) == :ok
      [_, {:post, _, %{"body" => body}, _}] = GitHubRequester.requests(requester)
      assert body =~ words
    end
  end

  test "a lost review acknowledgment is recovered before consuming the request label" do
    {binding, input} = request()
    {:ok, requester} = GitHubRequester.start([response(200, []), {:error, :timeout}])

    {:ok, client} =
      Client.new(
        http: requester,
        requester: GitHubRequester,
        ryker_actor_id: binding.ryker_actor_id
      )

    assert {:error, _} = RequestFeedback.deliver(binding, input, :review_requested, client)
    assert [_, {:post, _, %{"body" => body}, _}] = GitHubRequester.requests(requester)

    {:ok, retry_requester} =
      GitHubRequester.start([
        response(200, [
          %{"id" => 701, "body" => body, "user" => %{"id" => binding.ryker_actor_id}}
        ]),
        response(200, [%{"name" => "bug"}])
      ])

    {:ok, retry_client} =
      Client.new(
        http: retry_requester,
        requester: GitHubRequester,
        ryker_actor_id: binding.ryker_actor_id
      )

    assert RequestFeedback.deliver(binding, input, :review_requested, retry_client) == :ok

    assert [
             {:get, _, nil, _},
             {:delete, "/repos/octo/example/issues/42/labels/ryker%3Areview", nil, _}
           ] = GitHubRequester.requests(retry_requester)
  end

  defp request do
    {:ok, binding} =
      Ryker.GitHub.Binding.new(%{
        name: "github-main",
        installation_id: 41,
        repository_id: 99,
        repository_full_name: "octo/example",
        ryker_actor_id: 99
      })

    event = %{
      delivery_ref: "feedback",
      event_ref: "event:feedback",
      event_name: "issue_comment",
      payload: %{
        "action" => "created",
        "installation" => %{"id" => 41},
        "repository" => %{"id" => 99, "full_name" => "octo/example"},
        "sender" => %{"id" => 7, "type" => "User"},
        "comment" => %{
          "id" => 9001,
          "body" => "@ryker-test review this",
          "created_at" => "2026-08-28T12:00:00Z"
        },
        "issue" => %{"number" => 42, "pull_request" => %{}}
      }
    }

    {:ok, input} = Input.normalize(event, binding)
    {binding, input}
  end

  defp response(status, body), do: {:ok, %{status: status, body: body, headers: []}}
end
