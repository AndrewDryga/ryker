defmodule Ryker.GitHub.Client.Context do
  @moduledoc """
  One bounded section of an issue or pull request, read for the model: the
  subject itself, its issue comments, reviews, review comments or one review
  thread, or its changed files.

  Every item is re-shaped into the few fields the model may see and its text
  is cut to a byte bound that says so. A review comment's parents that are not
  on the page are read one by one, at most four, and only from the same pull
  request, so a thread never silently loses its context. Coverage says whether
  the provider page was complete.
  """

  alias Ryker.GitHub.Client.{Fields, Transport}

  @maximum_review_parents 4
  @context_fields ~w(limit number page repository review_root_id section subject_kind)a
  @context_sections ~w(subject issue_comments reviews review_comments review_thread files)

  def read_context(client, request) do
    with {:ok, request} <- context_request(request),
         {:ok, response} <- request_context(client, request),
         {:ok, items, provider_count} <- context_items(response, request),
         {:ok, parents} <- review_parents(client, request, items) do
      {:ok, Map.merge(context_result(request, items, provider_count), parents)}
    end
  end

  # --- the request ----------------------------------------------------------

  defp context_request(%{} = request) do
    with true <- Enum.sort(Map.keys(request)) == Enum.sort(@context_fields),
         :ok <- Fields.target(request.repository, request.number),
         true <- request.subject_kind in ["issue", "pull"],
         true <- request.section in @context_sections,
         true <- context_section?(request.subject_kind, request.section),
         true <- Fields.context_page?(request.page),
         true <- Fields.context_limit?(request.limit),
         true <- valid_review_root?(request.subject_kind, request.review_root_id) do
      {:ok, request}
    else
      _invalid -> {:error, {:invalid_github_api_request, :context}}
    end
  end

  defp context_request(_request), do: {:error, {:invalid_github_api_request, :context}}

  defp context_section?("issue", section), do: section in ~w(subject issue_comments)
  defp context_section?("pull", section), do: section in @context_sections

  defp valid_review_root?("issue", nil), do: true
  defp valid_review_root?("pull", nil), do: true
  defp valid_review_root?("pull", value), do: is_integer(value) and value > 0

  defp request_context(client, %{section: "subject", subject_kind: kind} = request) do
    noun = if kind == "pull", do: "pulls", else: "issues"

    Transport.request(
      client,
      :get,
      "/repos/#{request.repository}/#{noun}/#{request.number}",
      nil
    )
  end

  defp request_context(client, request) do
    path = context_path(request)
    query = URI.encode_query(%{"page" => request.page, "per_page" => request.limit})
    Transport.request(client, :get, path <> "?" <> query, nil)
  end

  defp context_path(%{section: "issue_comments"} = request),
    do: "/repos/#{request.repository}/issues/#{request.number}/comments"

  defp context_path(%{section: "reviews"} = request),
    do: "/repos/#{request.repository}/pulls/#{request.number}/reviews"

  defp context_path(%{section: section} = request)
       when section in ["review_comments", "review_thread"],
       do: "/repos/#{request.repository}/pulls/#{request.number}/comments"

  defp context_path(%{section: "files"} = request),
    do: "/repos/#{request.repository}/pulls/#{request.number}/files"

  # --- the items ------------------------------------------------------------

  defp context_items(%{body: body, status: 200}, %{section: "subject"} = request) do
    with {:ok, item} <- subject_item(body, request) do
      {:ok, [item], 1}
    end
  end

  defp context_items(%{body: body, status: 200}, request) when is_list(body) do
    provider_count = length(body)

    body
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, items} ->
      case context_item(item, request.section) do
        {:ok, prepared} -> {:cont, {:ok, [prepared | items]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} ->
        {:ok, Enum.reverse(items) |> filter_context_items(request), provider_count}

      {:error, _reason} = error ->
        error
    end
  end

  defp context_items(%{status: 200}, _request),
    do: {:error, {:github_protocol_error, :context}}

  defp context_items(response, _request), do: Transport.error(response)

  defp subject_item(item, %{number: number, subject_kind: "pull"}) do
    with %{
           "additions" => additions,
           "base" => %{"ref" => base_ref, "sha" => base_sha},
           "changed_files" => changed_files,
           "deletions" => deletions,
           "draft" => draft,
           "head" => %{"ref" => head_ref, "sha" => head_sha},
           "html_url" => url,
           "id" => id,
           "merged" => merged,
           "number" => ^number,
           "state" => state,
           "title" => title,
           "updated_at" => updated_at,
           "user" => user
         } <- item,
         true <-
           Fields.positive_id?(id) and state in ["open", "closed"] and is_boolean(draft) and
             is_boolean(merged),
         true <- Enum.all?([additions, changed_files, deletions], &(is_integer(&1) and &1 >= 0)),
         true <-
           ref_value?(base_ref) and ref_value?(head_ref) and Fields.git_identity?(base_sha) and
             Fields.git_identity?(head_sha),
         {:ok, author} <- Fields.context_actor(user),
         {:ok, title, _title_truncated} <- Fields.context_text(title, false),
         {:ok, body, truncated} <- Fields.context_text(Map.get(item, "body"), true),
         :ok <- Fields.context_url(url),
         :ok <- Fields.context_datetime(updated_at) do
      {:ok,
       %{
         "additions" => additions,
         "author" => author,
         "base_ref" => base_ref,
         "base_sha" => base_sha,
         "body" => body,
         "body_truncated" => truncated,
         "changed_files" => changed_files,
         "deletions" => deletions,
         "draft" => draft,
         "head_ref" => head_ref,
         "head_sha" => head_sha,
         "id" => id,
         "kind" => "pull_request",
         "merged" => merged,
         "number" => number,
         "state" => state,
         "title" => title,
         "updated_at" => updated_at,
         "url" => url
       }}
    else
      _invalid -> {:error, {:github_protocol_error, :context_subject}}
    end
  end

  defp subject_item(item, %{number: number, subject_kind: "issue"}) do
    with %{
           "html_url" => url,
           "id" => id,
           "number" => ^number,
           "state" => state,
           "title" => title,
           "updated_at" => updated_at,
           "user" => user
         } <- item,
         true <- Fields.positive_id?(id) and state in ["open", "closed"],
         {:ok, author} <- Fields.context_actor(user),
         {:ok, title, _title_truncated} <- Fields.context_text(title, false),
         {:ok, body, truncated} <- Fields.context_text(Map.get(item, "body"), true),
         :ok <- Fields.context_url(url),
         :ok <- Fields.context_datetime(updated_at) do
      {:ok,
       %{
         "author" => author,
         "body" => body,
         "body_truncated" => truncated,
         "id" => id,
         "kind" => "issue",
         "number" => number,
         "state" => state,
         "title" => title,
         "updated_at" => updated_at,
         "url" => url
       }}
    else
      _invalid -> {:error, {:github_protocol_error, :context_subject}}
    end
  end

  defp subject_item(_item, _request), do: {:error, {:github_protocol_error, :context_subject}}

  defp context_item(item, "issue_comments"), do: comment_item(item, "issue_comment")

  defp context_item(item, "reviews") do
    with %{
           "html_url" => url,
           "id" => id,
           "state" => state,
           "submitted_at" => submitted_at,
           "user" => user
         } <- item,
         true <- Fields.positive_id?(id) and is_binary(state),
         {:ok, author} <- Fields.context_actor(user),
         {:ok, body, truncated} <- Fields.context_text(Map.get(item, "body"), true),
         :ok <- Fields.context_url(url),
         :ok <- Fields.context_datetime(submitted_at) do
      {:ok,
       %{
         "author" => author,
         "body" => body,
         "body_truncated" => truncated,
         "id" => id,
         "kind" => "pull_request_review",
         "state" => String.downcase(state),
         "submitted_at" => submitted_at,
         "url" => url
       }}
    else
      _invalid -> {:error, {:github_protocol_error, :context_review}}
    end
  end

  defp context_item(item, section) when section in ["review_comments", "review_thread"] do
    with {:ok, comment} <- comment_item(item, "pull_request_review_comment"),
         path when is_binary(path) <- Map.get(item, "path"),
         true <- byte_size(path) in 1..1_024,
         line when is_integer(line) and line >= 0 <- Map.get(item, "line") || 0,
         side when side in ["LEFT", "RIGHT", nil] <- Map.get(item, "side"),
         reply when is_nil(reply) or (is_integer(reply) and reply > 0) <-
           Map.get(item, "in_reply_to_id") do
      {:ok,
       Map.merge(comment, %{
         "in_reply_to_id" => reply,
         "line" => line,
         "path" => path,
         "side" => side
       })}
    else
      _invalid -> {:error, {:github_protocol_error, :context_review_comment}}
    end
  end

  defp context_item(item, "files") do
    with %{
           "additions" => additions,
           "changes" => changes,
           "deletions" => deletions,
           "filename" => filename,
           "status" => status
         } <- item,
         true <- Enum.all?([additions, changes, deletions], &(is_integer(&1) and &1 >= 0)),
         true <- is_binary(filename) and byte_size(filename) in 1..1_024,
         true <- status in ~w(added removed modified renamed copied changed unchanged) do
      {:ok,
       %{
         "additions" => additions,
         "changes" => changes,
         "deletions" => deletions,
         "filename" => filename,
         "patch" => Fields.bounded_optional_text(Map.get(item, "patch")),
         "status" => status
       }}
    else
      _invalid -> {:error, {:github_protocol_error, :context_file}}
    end
  end

  defp comment_item(item, kind) do
    with %{
           "created_at" => created_at,
           "html_url" => url,
           "id" => id,
           "updated_at" => updated_at,
           "user" => user
         } <- item,
         true <- Fields.positive_id?(id),
         {:ok, author} <- Fields.context_actor(user),
         {:ok, body, truncated} <- Fields.context_text(Map.get(item, "body"), true),
         :ok <- Fields.context_url(url),
         :ok <- Fields.context_datetime(created_at),
         :ok <- Fields.context_datetime(updated_at) do
      {:ok,
       %{
         "author" => author,
         "body" => body,
         "body_truncated" => truncated,
         "created_at" => created_at,
         "id" => id,
         "kind" => kind,
         "updated_at" => updated_at,
         "url" => url
       }}
    else
      _invalid -> {:error, {:github_protocol_error, :context_comment}}
    end
  end

  defp filter_context_items(items, %{section: "review_thread", review_root_id: root})
       when is_integer(root),
       do: Enum.filter(items, &(&1["id"] == root or &1["in_reply_to_id"] == root))

  defp filter_context_items(items, _request), do: items

  defp ref_value?(value), do: is_binary(value) and byte_size(value) in 1..240

  # --- the result -----------------------------------------------------------

  defp context_result(request, items, provider_count) do
    %{
      "items" => items,
      "next_cursor" =>
        if(request.section == "subject",
          do: nil,
          else: Fields.next_cursor(provider_count, request.page, request.limit)
        ),
      "repository" => request.repository,
      "section" => request.section,
      "subject" => %{"kind" => request.subject_kind, "number" => request.number},
      "coverage" => %{
        "basis" => "provider_page",
        "status" =>
          if(
            request.page == 1 and (request.section == "subject" or provider_count < request.limit),
            do: "complete",
            else: "partial"
          ),
        "page" => request.page,
        "limit" => request.limit,
        "continuation_exhausted" =>
          Fields.last_context_page?(request.page) and provider_count >= request.limit
      }
    }
  end

  # --- review parents -------------------------------------------------------

  defp review_parents(client, %{section: section} = request, items)
       when section in ["review_comments", "review_thread"] do
    roots = if section == "review_thread", do: [request.review_root_id], else: []
    needed = Enum.uniq(roots ++ Enum.map(items, & &1["in_reply_to_id"])) -- [nil]
    present = Enum.map(items, & &1["id"])
    {fetch, omitted} = Enum.split(needed -- present, @maximum_review_parents)

    with {:ok, parents, unavailable} <- fetch_review_parents(client, request, fetch) do
      {:ok,
       %{
         "review_parents" => parents,
         "parent_coverage" => %{
           "status" => if(omitted == [] and unavailable == [], do: "complete", else: "partial"),
           "available_parent_ids" =>
             Enum.filter(needed, &(&1 in present)) ++ Enum.map(parents, & &1["id"]),
           "omitted_parent_ids" => omitted,
           "unavailable_parent_ids" => unavailable,
           "read_limit" => @maximum_review_parents
         }
       }}
    end
  end

  defp review_parents(_client, _request, _items), do: {:ok, %{}}

  defp fetch_review_parents(client, request, ids) do
    Enum.reduce_while(ids, {:ok, [], []}, fn id, {:ok, parents, unavailable} ->
      case read_review_parent(client, request, id) do
        {:ok, parent} -> {:cont, {:ok, parents ++ [parent], unavailable}}
        :not_found -> {:cont, {:ok, parents, unavailable ++ [id]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp read_review_parent(client, request, id) do
    path = "/repos/#{request.repository}/pulls/comments/#{id}"
    subject_url = "https://api.github.com/repos/#{request.repository}/pulls/#{request.number}"

    with {:ok, response} <- Transport.request(client, :get, path, nil) do
      case response do
        %{status: 200, body: %{"id" => ^id, "pull_request_url" => ^subject_url} = body} ->
          context_item(body, "review_comments")

        %{status: 200} ->
          {:error, {:github_protocol_error, :review_parent}}

        %{status: 404} ->
          :not_found

        other ->
          Transport.error(other)
      end
    end
  end
end
