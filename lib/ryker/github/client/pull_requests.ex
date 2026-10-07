defmodule Ryker.GitHub.Client.PullRequests do
  @moduledoc """
  Pull requests: the exact pull request with its check state, and a review
  published only while the head it was written against is still current.
  Coop's worker opens and updates pull requests.

  A pull request is handed on only in the shape Ryker records: typed author,
  exact refs and head SHA, a github.com pull URL, and a merge SHA and time
  exactly when it merged.
  """

  alias Ryker.GitHub.Client.{Checks, Fields, Transport}
  alias Ryker.GitObject

  def get_pull_request(client, repository, number) do
    with :ok <- Fields.target(repository, number),
         {:ok, response} <-
           Transport.request(client, :get, "/repos/#{repository}/pulls/#{number}", nil) do
      case response do
        %{body: pull, status: 200} -> pull_request(pull)
        other -> Transport.error(other)
      end
    end
  end

  # The lifecycle document holds exactly its own fields
  # (`Ryker.Publication.LifecycleStatus`), so the pull request's author, which
  # other callers read, stays out of it.
  def get_publication_status(client, repository, number) do
    with {:ok, pull} <- get_pull_request(client, repository, number),
         {:ok, checks} <- Checks.summary(client, repository, pull["head_sha"]) do
      {:ok,
       pull
       |> Map.drop(["author_id", "author_type"])
       |> Map.merge(%{
         "checks_failed" => checks.failed,
         "checks_passed" => checks.passed,
         "checks_state" => checks.state,
         "checks_total" => checks.total,
         "checks_url" => "https://github.com/#{repository}/pull/#{number}/checks"
       })}
    end
  end

  def submit_review(client, repository, number, head_sha, event, body, comments) do
    with :ok <- Fields.target(repository, number),
         :ok <- Fields.sha(head_sha),
         true <- event in ~w(COMMENT REQUEST_CHANGES APPROVE),
         :ok <- Fields.text(body),
         {:ok, comments} <- review_comments(comments),
         {:ok, pull_response} <-
           Transport.request(client, :get, "/repos/#{repository}/pulls/#{number}", nil),
         :ok <- current_pull_head(pull_response, head_sha),
         {:ok, response} <-
           Transport.request(client, :post, "/repos/#{repository}/pulls/#{number}/reviews", %{
             "body" => body,
             "comments" => comments,
             "commit_id" => head_sha,
             "event" => event
           }) do
      case response do
        %{body: %{"html_url" => url, "id" => id}, status: 200} when is_integer(id) ->
          {:ok,
           %{
             "commit_id" => head_sha,
             "review_id" => id,
             "status" => String.downcase(event),
             "url" => url
           }}

        %{body: %{"html_url" => url, "id" => id}, status: 201} when is_integer(id) ->
          {:ok,
           %{
             "commit_id" => head_sha,
             "review_id" => id,
             "status" => String.downcase(event),
             "url" => url
           }}

        other ->
          Transport.error(other)
      end
    else
      false -> {:error, {:invalid_github_api_request, :review_event}}
      {:error, _reason} = error -> error
    end
  end

  defp review_comments(comments) when is_list(comments) and length(comments) <= 20 do
    comments
    |> Enum.reduce_while({:ok, []}, fn comment, {:ok, prepared} ->
      case review_comment(comment) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | prepared]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      {:error, _reason} = error -> error
    end
  end

  defp review_comments(_comments), do: {:error, {:invalid_github_api_request, :review_comments}}

  defp review_comment(%{"body" => body, "line" => line, "path" => path, "side" => side})
       when is_binary(body) and byte_size(body) in 1..12_000 and is_integer(line) and line > 0 and
              is_binary(path) and byte_size(path) in 1..1_024 and side in ["LEFT", "RIGHT"] do
    {:ok, %{"body" => body, "line" => line, "path" => path, "side" => side}}
  end

  defp review_comment(_comment), do: {:error, {:invalid_github_api_request, :review_comment}}

  defp current_pull_head(%{body: %{"head" => %{"sha" => head_sha}}, status: 200}, head_sha),
    do: :ok

  defp current_pull_head(%{status: 200}, _head_sha),
    do: {:error, {:github_action_unavailable, :stale_head}}

  defp current_pull_head(response, _head_sha), do: Transport.error(response)

  defp pull_request(
         %{
           "base" => %{"ref" => base_ref},
           "draft" => draft,
           "head" => %{"ref" => head_ref, "sha" => head_sha},
           "html_url" => url,
           "merged" => merged,
           "number" => number,
           "state" => state,
           "user" => %{"id" => author_id, "type" => author_type}
         } = pull
       ) do
    with true <- is_integer(number) and number > 0,
         true <- is_integer(author_id) and author_id > 0 and author_type in ["Bot", "User"],
         true <- is_boolean(draft) and is_boolean(merged),
         true <- state in ["open", "closed"],
         :ok <- Fields.ref_component(base_ref),
         :ok <- Fields.ref_component(head_ref),
         true <- GitObject.id?(head_sha),
         true <- github_pull_url?(url) do
      with {:ok, merge_sha, merged_at} <- merge_identity(pull) do
        {:ok,
         %{
           "author_id" => author_id,
           "author_type" => author_type,
           "base_ref" => base_ref,
           "draft" => draft,
           "head_ref" => head_ref,
           "head_sha" => head_sha,
           "merge_sha" => merge_sha,
           "merged" => merged,
           "merged_at" => merged_at,
           "number" => number,
           "state" => state,
           "url" => url
         }}
      end
    else
      false -> {:error, {:github_protocol_error, :pull_request}}
      {:error, _reason} -> {:error, {:github_protocol_error, :pull_request}}
    end
  end

  defp pull_request(_pull), do: {:error, {:github_protocol_error, :pull_request}}

  defp merge_identity(%{"merged" => true} = pull) do
    sha = pull["merge_commit_sha"]

    with true <- GitObject.id?(sha),
         {:ok, merged_at} <- github_datetime(pull["merged_at"]) do
      {:ok, sha, DateTime.to_iso8601(merged_at)}
    else
      _invalid -> {:error, {:github_protocol_error, :pull_request}}
    end
  end

  defp merge_identity(%{"merged" => false}), do: {:ok, nil, nil}

  defp github_datetime(value) do
    case DateTime.from_iso8601(value || "") do
      {:ok, datetime, 0} -> {:ok, datetime}
      _invalid -> {:error, :datetime}
    end
  end

  defp github_pull_url?(value) when is_binary(value) and byte_size(value) <= 2_048 do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: "github.com", path: path}} ->
        is_binary(path) and
          Regex.match?(~r/\A\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/[1-9][0-9]*\z/, path)

      _invalid ->
        false
    end
  end

  defp github_pull_url?(_value), do: false
end
