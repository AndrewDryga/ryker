defmodule Ryker.GitHub.ReviewFindings do
  @moduledoc "Current, unresolved Ryker findings and the signed-in person's thumbs-ups."
  alias Ryker.CanonicalJSON
  alias Ryker.GitHub
  alias Ryker.GitObject
  alias Ryker.Maps

  @query """
  query RykerReviewFindings($owner: String!, $name: String!, $number: Int!, $after: String) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        headRefOid headRefName baseRefName state url
        repository { databaseId }
        headRepository { nameWithOwner databaseId }
        baseRepository { databaseId }
        reviewThreads(first: 100, after: $after) {
          pageInfo { hasNextPage endCursor }
          nodes {
            id isResolved isOutdated path line
            comments(first: 1) {
              nodes { databaseId body updatedAt url author { login ... on Bot { databaseId } }
                commit { oid } reactionGroups { content viewerHasReacted } }
            }
          }
        }
      }
    }
  }
  """

  @doc "Reads at most 500 threads; incomplete or changing snapshots are refused."
  def fetch(access, number, options) when is_integer(number) and number > 0 do
    [owner, name] = String.split(access.repository.github_repository, "/")
    variables = %{"owner" => owner, "name" => name, "number" => number, "after" => nil}
    bot_id = access.binding.ryker_actor_id

    with {:ok, pull, threads} <- pages(access.http, variables, nil, [], 5, options),
         "OPEN" <- pull["state"],
         true <- GitObject.id?(pull["headRefOid"]),
         true <- get_in(pull, ["repository", "databaseId"]) == access.binding.repository_id,
         true <- get_in(pull, ["headRepository", "databaseId"]) == access.binding.repository_id,
         true <- get_in(pull, ["baseRepository", "databaseId"]) == access.binding.repository_id,
         true <-
           get_in(pull, ["headRepository", "nameWithOwner"]) ==
             access.repository.github_repository do
      findings = Enum.flat_map(threads, &finding(&1, bot_id, pull["headRefOid"]))

      {:ok,
       %{
         pull: Map.drop(pull, ["reviewThreads"]),
         findings: findings,
         number: number,
         binding: access.binding.name,
         app_actor_id: bot_id,
         installation_id: access.binding.installation_id
       }}
    else
      {:error, reason} -> {:error, reason}
      _unavailable -> {:error, :pull_request_unavailable}
    end
  end

  def fetch(_access, _number, _options), do: {:error, :invalid_action_link}

  @doc "Binds the displayed comment versions and head, without binding later reaction changes."
  def snapshot(review) do
    %{
      "binding" => review.binding,
      "number" => review.number,
      "target" => review.pull,
      "app_actor_id" => review.app_actor_id,
      "installation_id" => review.installation_id,
      "findings" => Enum.map(review.findings, &Map.drop(&1, ["selected"]))
    }
    |> CanonicalJSON.digest()
  end

  @doc "Only checkboxes from the unchanged displayed snapshot may become work."
  def select(review, expected, ids) when is_list(ids) and length(ids) in 1..20 do
    selected = Enum.filter(review.findings, &(&1["thread_id"] in ids))

    cond do
      snapshot(review) != expected -> {:error, :review_changed}
      length(selected) != length(Enum.uniq(ids)) -> {:error, :invalid_selection}
      true -> {:ok, Enum.map(selected, &Map.drop(&1, ["selected"]))}
    end
  end

  def select(_review, _expected, []), do: {:error, :empty_selection}
  def select(_review, _expected, _ids), do: {:error, :invalid_selection}

  @doc "The complete frozen comment version that a selected fix is allowed to address."
  def valid_finding?(finding) do
    Maps.exact_keys?(finding, ~w(thread_id comment_id body updated_at url path line)) and
      GitHub.id?(finding["comment_id"]) and is_integer(finding["line"]) and finding["line"] > 0 and
      Enum.all?(
        [{"thread_id", 256}, {"body", 12_000}, {"path", 1024}, {"updated_at", 64}, {"url", 2048}],
        fn {key, bound} ->
          bounded_text?(finding[key], bound)
        end
      ) and match?({:ok, _, _}, DateTime.from_iso8601(finding["updated_at"])) and
      match?({:ok, %URI{scheme: "https", userinfo: nil}}, URI.new(finding["url"]))
  end

  defp bounded_text?(value, bound) do
    is_binary(value) and String.valid?(value) and byte_size(value) in 1..bound and
      not String.contains?(value, <<0>>)
  end

  defp pages(_http, _variables, _pull, _threads, 0, _options),
    do: {:error, :too_many_review_threads}

  defp pages(http, variables, previous, threads, remaining, options) do
    with {:ok, %{"repository" => %{"pullRequest" => pull}}} <-
           GitHub.GraphQL.request(http, @query, variables, options),
         %{"reviewThreads" => %{"nodes" => nodes, "pageInfo" => page}} <- pull,
         true <- is_list(nodes),
         true <-
           is_nil(previous) or
             Map.drop(previous, ["reviewThreads"]) == Map.drop(pull, ["reviewThreads"]) do
      if page["hasNextPage"] == true do
        pages(
          http,
          %{variables | "after" => page["endCursor"]},
          pull,
          threads ++ nodes,
          remaining - 1,
          options
        )
      else
        {:ok, pull, threads ++ nodes}
      end
    else
      _unavailable -> {:error, :github_unavailable}
    end
  end

  defp finding(
         %{
           "isResolved" => false,
           "isOutdated" => false,
           "id" => id,
           "path" => path,
           "line" => line,
           "comments" => %{"nodes" => [comment]}
         },
         bot,
         head
       ) do
    if get_in(comment, ["author", "databaseId"]) == bot and not is_nil(bot) and
         get_in(comment, ["commit", "oid"]) == head do
      selected =
        Enum.any?(
          comment["reactionGroups"] || [],
          &(&1["content"] == "THUMBS_UP" and &1["viewerHasReacted"] == true)
        )

      finding = %{
        "thread_id" => id,
        "comment_id" => comment["databaseId"],
        "body" => comment["body"],
        "updated_at" => comment["updatedAt"],
        "url" => comment["url"],
        "path" => path,
        "line" => line
      }

      if valid_finding?(finding), do: [Map.put(finding, "selected", selected)], else: []
    else
      []
    end
  end

  defp finding(_thread, _bot, _head), do: []
end
