defmodule Ryker.GitHub.Client.ReviewThreads do
  @moduledoc "Resolve a selected, unchanged thread only on the published PR head."
  alias Ryker.GitHub.GraphQL

  @query """
  query RykerSelectedThread($id: ID!) {
    node(id: $id) { ... on PullRequestReviewThread {
      id isResolved
      pullRequest { number headRefOid headRefName baseRefName state
        repository { databaseId } headRepository { databaseId } baseRepository { databaseId } }
      comments(first: 1) { nodes { databaseId body updatedAt
        author { ... on Bot { databaseId } } commit { oid } } }
    } }
  }
  """
  @resolve """
  mutation RykerResolveSelectedThread($id: ID!) {
    resolveReviewThread(input: {threadId: $id}) { thread { id isResolved } }
  }
  """

  def resolve(client, target, finding, commit) do
    options = [requester: client.requester]

    with {:ok, %{"node" => %{} = thread}} <-
           GraphQL.request(client.http, @query, %{"id" => finding["thread_id"]}, options),
         true <- exact_thread?(thread, target, finding, commit),
         {:ok, result} <- resolve_current(client, thread, options) do
      {:ok, Map.put(result, "commit_sha", commit)}
    else
      false -> {:error, :review_changed}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :review_changed}
    end
  end

  defp exact_thread?(thread, target, finding, commit) do
    pull = thread["pullRequest"] || %{}

    case get_in(thread, ["comments", "nodes"]) do
      [comment] ->
        thread["id"] == finding["thread_id"] and
          Map.take(comment, ~w(databaseId body updatedAt)) == %{
            "databaseId" => finding["comment_id"],
            "body" => finding["body"],
            "updatedAt" => finding["updated_at"]
          } and
          get_in(comment, ["author", "databaseId"]) == target["app_actor_id"] and
          get_in(comment, ["commit", "oid"]) == target["head_commit"] and
          exact_pull?(pull, target, commit)

      _missing ->
        false
    end
  end

  defp exact_pull?(pull, target, commit) do
    Map.take(pull, ~w(number state headRefOid headRefName baseRefName)) == %{
      "number" => target["number"],
      "state" => "OPEN",
      "headRefOid" => commit,
      "headRefName" => String.replace_prefix(target["head_ref"], "refs/heads/", ""),
      "baseRefName" => String.replace_prefix(target["base_ref"], "refs/heads/", "")
    } and
      Enum.all?(
        ~w(repository headRepository baseRepository),
        &(get_in(pull, [&1, "databaseId"]) == target["repository_id"])
      )
  end

  defp resolve_current(_client, %{"isResolved" => true, "id" => id}, _options),
    do: {:ok, %{"thread_id" => id, "status" => "resolved"}}

  defp resolve_current(client, %{"isResolved" => false, "id" => id}, options) do
    case GraphQL.request(client.http, @resolve, %{"id" => id}, options) do
      {:ok, %{"resolveReviewThread" => %{"thread" => %{"id" => ^id, "isResolved" => true}}}} ->
        {:ok, %{"thread_id" => id, "status" => "resolved"}}

      _error ->
        {:error, :github_unavailable}
    end
  end

  defp resolve_current(_client, _thread, _options), do: {:error, :review_changed}
end
