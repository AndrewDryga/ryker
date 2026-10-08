defmodule Ryker.GitHub.Client.Comments do
  @moduledoc """
  Durable delivery on GitHub: issue comments, native pull-request reviews,
  inline review replies, and emoji reactions on either kind of comment.

  Each delivered body carries a marker. A retry walks the exact issue, review
  history or review thread for that marker before it writes again, and never
  reports absence until every bounded page was inspected, so a lost response
  cannot duplicate a visible comment.
  """
  alias Ryker.GitHub.Client.{Fields, Transport}

  @maximum_pages 100
  @page_size 100

  # --- issue comments -------------------------------------------------------

  def find_issue_comment(client, repository, number, marker) do
    with :ok <- Fields.target(repository, number),
         :ok <- Fields.text(marker) do
      find_comments(
        client,
        fn page ->
          "/repos/#{repository}/issues/#{number}/comments?per_page=#{@page_size}&page=#{page}"
        end,
        &marker_match(&1, marker)
      )
    end
  end

  def create_issue_comment(client, repository, number, body) do
    with :ok <- Fields.target(repository, number),
         :ok <- Fields.text(body),
         {:ok, response} <-
           Transport.request(
             client,
             :post,
             "/repos/#{repository}/issues/#{number}/comments",
             %{"body" => body}
           ) do
      created_comment(response)
    end
  end

  def update_issue_comment(client, repository, comment_id, body) do
    update_comment(
      client,
      repository,
      comment_id,
      body,
      "/repos/#{repository}/issues/comments/#{comment_id}"
    )
  end

  # --- pull-request reviews -------------------------------------------------

  def find_pull_review(client, repository, number, marker) do
    with :ok <- Fields.target(repository, number),
         :ok <- Fields.text(marker) do
      find_comments(
        client,
        fn page ->
          "/repos/#{repository}/pulls/#{number}/reviews?per_page=#{@page_size}&page=#{page}"
        end,
        &marker_match(&1, marker)
      )
    end
  end

  def create_pull_review(client, repository, number, body) do
    with :ok <- Fields.target(repository, number),
         :ok <- Fields.text(body),
         {:ok, response} <-
           Transport.request(client, :post, "/repos/#{repository}/pulls/#{number}/reviews", %{
             "body" => body,
             "event" => "COMMENT"
           }) do
      created_review(response)
    end
  end

  def update_pull_review(client, repository, number, review_id, body) do
    with :ok <- Fields.target(repository, number),
         :ok <- Fields.positive_id(review_id),
         :ok <- Fields.text(body),
         {:ok, response} <-
           Transport.request(
             client,
             :put,
             "/repos/#{repository}/pulls/#{number}/reviews/#{review_id}",
             %{"body" => body}
           ) do
      case response do
        %{body: %{"id" => ^review_id}, status: 200} -> :ok
        %{status: 200} -> {:error, {:github_protocol_error, :pull_review}}
        other -> Transport.error(other)
      end
    end
  end

  # --- review replies -------------------------------------------------------

  def find_review_reply(client, repository, number, root_id, marker) do
    with :ok <- Fields.target(repository, number),
         :ok <- Fields.positive_id(root_id),
         :ok <- Fields.text(marker) do
      find_comments(
        client,
        fn page ->
          "/repos/#{repository}/pulls/#{number}/comments?per_page=#{@page_size}&page=#{page}"
        end,
        &review_marker_match(&1, root_id, marker)
      )
    end
  end

  def create_review_reply(client, repository, number, root_id, body) do
    with :ok <- Fields.target(repository, number),
         :ok <- Fields.positive_id(root_id),
         :ok <- Fields.text(body),
         {:ok, response} <-
           Transport.request(
             client,
             :post,
             "/repos/#{repository}/pulls/#{number}/comments/#{root_id}/replies",
             %{"body" => body}
           ) do
      created_comment(response)
    end
  end

  def update_review_comment(client, repository, comment_id, body) do
    update_comment(
      client,
      repository,
      comment_id,
      body,
      "/repos/#{repository}/pulls/comments/#{comment_id}"
    )
  end

  # --- reactions ------------------------------------------------------------

  def add_issue_comment_reaction(client, repository, comment_id, emoji_name) do
    reaction(
      client,
      repository,
      comment_id,
      emoji_name,
      "/repos/#{repository}/issues/comments/#{comment_id}/reactions"
    )
  end

  def add_review_comment_reaction(client, repository, comment_id, emoji_name) do
    reaction(
      client,
      repository,
      comment_id,
      emoji_name,
      "/repos/#{repository}/pulls/comments/#{comment_id}/reactions"
    )
  end

  # --- the bounded marker walk ----------------------------------------------

  defp find_comments(client, path, matcher, page \\ 1) do
    with {:ok, response} <- Transport.request(client, :get, path.(page), nil),
         {:ok, comments} <- comments(response) do
      case find_comment(comments, matcher) do
        {:ok, id} ->
          {:ok, id}

        :not_found when length(comments) < @page_size ->
          :not_found

        :not_found when page < @maximum_pages ->
          find_comments(client, path, matcher, page + 1)

        :not_found ->
          {:error, {:github_reconciliation_incomplete, @maximum_pages * @page_size}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp find_comment(comments, matcher) do
    Enum.reduce_while(comments, :not_found, fn comment, :not_found ->
      case matcher.(comment) do
        :not_found -> {:cont, :not_found}
        result -> {:halt, result}
      end
    end)
  end

  defp marker_match(%{"body" => body, "id" => id}, marker) when is_binary(body) do
    if String.contains?(body, marker), do: valid_comment_id(id), else: :not_found
  end

  defp marker_match(%{}, _marker), do: :not_found
  defp marker_match(_comment, _marker), do: {:error, {:github_protocol_error, :comment}}

  defp review_marker_match(%{"in_reply_to_id" => root_id} = comment, root_id, marker),
    do: marker_match(comment, marker)

  defp review_marker_match(%{}, _root_id, _marker), do: :not_found

  defp review_marker_match(_comment, _root_id, _marker),
    do: {:error, {:github_protocol_error, :comment}}

  defp comments(%{body: body, status: 200}) when is_list(body), do: {:ok, body}
  defp comments(%{status: 200}), do: {:error, {:github_protocol_error, :comments}}
  defp comments(response), do: Transport.error(response)

  # --- writes ---------------------------------------------------------------

  defp created_comment(%{body: %{"id" => id}, status: 201}), do: valid_comment_id(id)
  defp created_comment(%{status: 201}), do: {:error, {:github_protocol_error, :comment}}
  defp created_comment(response), do: Transport.error(response)

  # GitHub answers a new pull request review with 200, unlike a new comment's 201; treating it
  # as an error recorded a posted reply as failed (AndrewDryga/test#3, 2026-09-30).
  defp created_review(%{body: %{"body" => body, "id" => id}, status: status})
       when status in [200, 201] and is_binary(body),
       do: valid_comment_id(id)

  defp created_review(%{status: status}) when status in [200, 201],
    do: {:error, {:github_protocol_error, :pull_review}}

  defp created_review(response), do: Transport.error(response)

  defp update_comment(client, repository, comment_id, body, path) do
    with :ok <- Fields.repository(repository),
         :ok <- Fields.positive_id(comment_id),
         :ok <- Fields.text(body),
         {:ok, response} <- Transport.request(client, :patch, path, %{"body" => body}) do
      case response do
        %{body: %{"id" => ^comment_id}, status: 200} -> :ok
        %{status: 200} -> {:error, {:github_protocol_error, :comment}}
        other -> Transport.error(other)
      end
    end
  end

  defp reaction(client, repository, comment_id, emoji_name, path) do
    with :ok <- Fields.target(repository, comment_id),
         :ok <- Fields.text(emoji_name),
         {:ok, response} <- Transport.request(client, :post, path, %{"content" => emoji_name}) do
      case response do
        %{status: status} when status in [200, 201] -> :ok
        other -> Transport.error(other)
      end
    end
  end

  defp valid_comment_id(id) when is_integer(id) and id > 0, do: {:ok, id}
  defp valid_comment_id(_id), do: {:error, {:github_protocol_error, :comment}}
end
