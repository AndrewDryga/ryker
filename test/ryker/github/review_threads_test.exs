defmodule Ryker.GitHub.ReviewThreadsTest do
  use ExUnit.Case, async: true
  alias Ryker.Delivery.JSONClient
  alias Ryker.GitHub.Client.ReviewThreads

  defmodule Requester do
    def request(http, :post, "/graphql", document, _headers) do
      {:ok, owner} = http.token_provider.()
      send(owner, {:query, document})

      receive do
        {:respond, data} -> {:ok, %{status: 200, body: %{"data" => data}}}
      end
    end
  end

  setup do
    target = Ryker.Fixtures.GitHubActions.publication_target()
    finding = hd(target["findings"])
    commit = String.duplicate("c", 40)
    owner = self()

    http = %JSONClient{
      base_url: "https://api.github.com",
      finch: Ryker.CoopFinch,
      receive_timeout: 1000,
      token_provider: fn -> {:ok, owner} end
    }

    client = %{http: http, requester: Requester}

    thread = Ryker.Fixtures.GitHubActions.review_thread(target, commit)

    %{target: target, finding: finding, commit: commit, client: client, thread: thread}
  end

  test "the selected unchanged thread resolves once and a lost response can be reconciled", %{
    target: target,
    finding: finding,
    commit: commit,
    client: client,
    thread: thread
  } do
    task = Task.async(fn -> ReviewThreads.resolve(client, target, finding, commit) end)
    assert_receive {:query, %{"variables" => %{"id" => "thread-one"}}}
    send(task.pid, {:respond, %{"node" => thread}})
    assert_receive {:query, %{"query" => mutation, "variables" => %{"id" => "thread-one"}}}
    assert mutation =~ "resolveReviewThread"

    send(
      task.pid,
      {:respond,
       %{"resolveReviewThread" => %{"thread" => %{"id" => "thread-one", "isResolved" => true}}}}
    )

    assert {:ok, %{"status" => "resolved", "commit_sha" => published_commit}} = Task.await(task)
    assert published_commit == commit

    task = Task.async(fn -> ReviewThreads.resolve(client, target, finding, commit) end)
    assert_receive {:query, _read}
    send(task.pid, {:respond, %{"node" => %{thread | "isResolved" => true}}})
    assert {:ok, %{"status" => "resolved"}} = Task.await(task)
    refute_receive {:query, _mutation}
  end

  test "new commits, retargeting and edited findings remain open", %{
    target: target,
    finding: finding,
    commit: commit,
    client: client,
    thread: thread
  } do
    [comment] = thread["comments"]["nodes"]

    for thread <- [
          put_in(thread, ["pullRequest", "headRefOid"], String.duplicate("d", 40)),
          put_in(thread, ["pullRequest", "baseRefName"], "release"),
          put_in(thread, ["pullRequest", "headRepository", "databaseId"], 18),
          put_in(thread, ["comments", "nodes"], [%{comment | "body" => "A different issue."}]),
          put_in(thread, ["comments", "nodes"], [put_in(comment, ["author", "databaseId"], 31)])
        ] do
      task = Task.async(fn -> ReviewThreads.resolve(client, target, finding, commit) end)
      assert_receive {:query, _read}
      send(task.pid, {:respond, %{"node" => thread}})
      assert Task.await(task) == {:error, :review_changed}
      refute_receive {:query, _mutation}
    end
  end
end
