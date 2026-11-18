defmodule Ryker.GitHub.Client.IssueTriage do
  @moduledoc "Bounded issue-index reads and additive, existing-label changes."
  alias Ryker.GitHub.Client.{Context, Fields, Transport}

  def repository(client, repository, id) do
    with :ok <- Fields.repository(repository),
         {:ok, response} <- Transport.request(client, :get, "/repos/#{repository}", nil) do
      case response do
        %{status: 200, body: %{"id" => ^id}} -> :ok
        %{status: 200} -> {:error, :repository_access_changed}
        other -> Transport.error(other)
      end
    end
  end

  def page(client, repository, page) when page in 1..5 do
    path =
      "/repos/#{repository}/issues?state=all&sort=created&direction=desc&per_page=20&page=#{page}"

    with :ok <- Fields.repository(repository),
         {:ok, response} <- Transport.request(client, :get, path, nil) do
      page_result(response)
    end
  end

  defp page_result(%{status: 200, body: items}) when is_list(items) and length(items) <= 20 do
    if Enum.all?(items, &match?(%{"number" => n} when is_integer(n) and n > 0, &1)) do
      {:ok,
       %{
         numbers: for(item <- items, is_nil(item["pull_request"]), do: item["number"]),
         complete: length(items) < 20
       }}
    else
      {:error, :invalid_issue_page}
    end
  end

  defp page_result(response), do: Transport.error(response)

  def read(client, repository, number) do
    with :ok <- Fields.target(repository, number),
         {:ok, response} <-
           Transport.request(client, :get, "/repos/#{repository}/issues/#{number}", nil),
         {:ok, issue} <- issue(response, number),
         {:ok, discussion} <-
           Context.read_context(client, %{
             repository: repository,
             number: number,
             subject_kind: "issue",
             section: "issue_comments",
             review_root_id: nil,
             page: 1,
             limit: 20
           }) do
      {:ok,
       %{
         "issue" => issue,
         "discussion" => bounded_discussion(discussion),
         "observed_at" => DateTime.to_iso8601(DateTime.utc_now(:second))
       }}
    end
  end

  defp bounded_discussion(discussion) do
    items =
      Enum.map(discussion["items"], fn item ->
        body = item["body"] || ""

        item
        |> Map.take(~w(id updated_at body body_truncated))
        |> Map.put("body", String.byte_slice(body, 0, 2000))
        |> Map.put("body_truncated", item["body_truncated"] or byte_size(body) > 2000)
      end)

    discussion |> Map.put("items", items) |> Map.put("comment_body_limit_bytes", 2000)
  end

  defp issue(
         %{status: 200, body: %{"number" => number, "id" => id, "state" => state} = body},
         number
       ) do
    with true <-
           Fields.positive_id?(id) and state in ["open", "closed"] and
             is_nil(body["pull_request"]),
         {:ok, title, _cut} <- Fields.context_text(body["title"], false),
         text <- body["body"] || "",
         true <- is_binary(text) and String.valid?(text),
         cut <- byte_size(text) > 48_000,
         :ok <- Fields.context_datetime(body["updated_at"]) do
      {:ok,
       %{
         "id" => id,
         "number" => number,
         "state" => state,
         "title" => title,
         "body" => String.byte_slice(text, 0, 48_000),
         "body_truncated" => cut,
         "updated_at" => body["updated_at"]
       }}
    else
      _invalid -> {:error, :issue_unavailable}
    end
  end

  defp issue(%{status: status}, _number) when status in [404, 410],
    do: {:error, :issue_unavailable}

  defp issue(response, _number), do: Transport.error(response)

  def labels(client, repository) do
    with :ok <- Fields.repository(repository),
         {:ok, response} <-
           Transport.request(client, :get, "/repos/#{repository}/labels?per_page=100&page=1", nil) do
      label_result(response)
    end
  end

  defp label_result(%{status: 200, body: items}) when is_list(items) and length(items) <= 100 do
    if Enum.all?(items, &match?(%{"name" => name} when is_binary(name), &1)) do
      {:ok,
       %{
         "names" => Enum.map(items, & &1["name"]),
         "coverage" => if(length(items) == 100, do: "partial", else: "complete")
       }}
    else
      {:error, :invalid_labels}
    end
  end

  defp label_result(response), do: Transport.error(response)

  def add_existing_labels(client, repository, number, names) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      path = "/repos/#{repository}/labels/#{URI.encode(name, &URI.char_unreserved?/1)}"

      with :ok <- Fields.target(repository, number),
           {:ok, %{status: 200, body: %{"name" => ^name}}} <-
             Transport.request(client, :get, path, nil),
           :ok <- Ryker.GitHub.Client.Labels.add_pull_label(client, repository, number, name) do
        {:cont, :ok}
      else
        _unavailable -> {:halt, {:error, :labels_unavailable}}
      end
    end)
  end
end
