defmodule Ryker.GitHub.Client.Search do
  @moduledoc """
  Issue and pull-request search, for the model, inside exactly one repository.

  The query may not name its own repository, organization or user: Ryker adds
  the repository it was asked about, and refuses any result GitHub returns
  from elsewhere rather than dropping it quietly. An incomplete provider
  result is a protocol error, not a shorter list.
  """

  alias Ryker.GitHub.Client.{Fields, Transport}

  @search_fields ~w(kind limit page query repository state)a

  def search(client, request) do
    with {:ok, request} <- search_request(request),
         query <- search_query(request),
         encoded <-
           URI.encode_query(%{"page" => request.page, "per_page" => request.limit, "q" => query}),
         {:ok, response} <- Transport.request(client, :get, "/search/issues?#{encoded}", nil),
         {:ok, items, total} <- search_items(response, request) do
      {:ok,
       %{
         "items" => items,
         "next_cursor" => Fields.next_cursor(items, request.page, request.limit),
         "repository" => request.repository,
         "total_count" => total
       }}
    end
  end

  defp search_request(%{} = request) do
    with true <- Enum.sort(Map.keys(request)) == Enum.sort(@search_fields),
         :ok <- Fields.repository(request.repository),
         true <- request.kind in ["issues", "pull_requests", "all"],
         true <- request.state in ["open", "closed", "all"],
         true <- Fields.context_page?(request.page),
         true <- Fields.context_limit?(request.limit),
         true <- valid_search_query?(request.query) do
      {:ok, request}
    else
      _invalid -> {:error, {:invalid_github_api_request, :search}}
    end
  end

  defp search_request(_request), do: {:error, {:invalid_github_api_request, :search}}

  defp valid_search_query?(value) do
    is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_000 and
      String.trim(value) != "" and not Regex.match?(~r/(?:\A|\s)(?:repo|org|user):/i, value)
  end

  defp search_query(request) do
    kind =
      if request.kind == "all",
        do: "",
        else: " is:" <> if(request.kind == "issues", do: "issue", else: "pr")

    state = if request.state == "all", do: "", else: " state:" <> request.state
    String.trim(request.query) <> " repo:" <> request.repository <> kind <> state
  end

  defp search_items(
         %{
           body: %{"incomplete_results" => false, "items" => items, "total_count" => total},
           status: 200
         },
         request
       )
       when is_list(items) and is_integer(total) and total >= 0 do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, prepared} ->
      case search_item(item, request) do
        {:ok, result} -> {:cont, {:ok, [result | prepared]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared), total}
      {:error, _reason} = error -> error
    end
  end

  defp search_items(%{status: 200}, _request),
    do: {:error, {:github_protocol_error, :search}}

  defp search_items(response, _request), do: Transport.error(response)

  defp search_item(item, request) do
    kind = if Map.has_key?(item, "pull_request"), do: "pull_request", else: "issue"

    with %{
           "html_url" => url,
           "id" => id,
           "number" => number,
           "repository_url" => repository_url,
           "state" => state,
           "title" => title,
           "updated_at" => updated_at,
           "user" => user
         } <- item,
         true <-
           Fields.positive_id?(id) and Fields.positive_id?(number) and
             state in ["open", "closed"],
         true <- search_kind_matches?(kind, request.kind),
         true <- repository_url?(repository_url, request.repository),
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
         "kind" => kind,
         "number" => number,
         "state" => state,
         "title" => title,
         "updated_at" => updated_at,
         "url" => url
       }}
    else
      false when is_map(item) -> {:error, {:github_protocol_error, :search_repository}}
      _invalid -> {:error, {:github_protocol_error, :search}}
    end
  end

  defp search_kind_matches?(_kind, "all"), do: true
  defp search_kind_matches?("issue", "issues"), do: true
  defp search_kind_matches?("pull_request", "pull_requests"), do: true
  defp search_kind_matches?(_kind, _requested), do: false

  defp repository_url?(value, repository) when is_binary(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: host, path: path}} when is_binary(host) ->
        path == "/repos/#{repository}"

      _invalid ->
        false
    end
  end

  defp repository_url?(_value, _repository), do: false
end
