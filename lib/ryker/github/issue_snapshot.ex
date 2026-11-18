defmodule Ryker.GitHub.IssueSnapshot do
  @moduledoc "A bounded, current issue read for a human action. Pull requests are refused."
  alias Ryker.CanonicalJSON
  alias Ryker.Delivery
  alias Ryker.GitHub

  def fetch(access, number, options \\ []) when is_integer(number) and number > 0 do
    requester = Keyword.get(options, :requester, Delivery.JSONClient)
    path = "/repos/#{access.repository.github_repository}/issues/#{number}"
    headers = [{"accept", "application/vnd.github+json"}, {"x-github-api-version", "2022-11-28"}]

    case requester.request(access.http, :get, path, nil, headers) do
      {:ok, %{status: 200, body: body}} -> prepare(access, number, body)
      _unavailable -> {:error, :issue_unavailable}
    end
  end

  @doc "The same bounds apply to an authenticated webhook's issue snapshot."
  def prepare(access, number, body) do
    with %{
           "id" => id,
           "number" => ^number,
           "state" => "open",
           "title" => title,
           "updated_at" => updated
         } <- body,
         true <- GitHub.id?(id) and GitHub.id?(number) and is_nil(body["pull_request"]),
         true <- is_binary(title) and byte_size(title) in 1..1024,
         text <- body["body"] || "",
         true <- is_binary(text) and byte_size(text) <= 48_000,
         true <- is_binary(updated),
         {:ok, _time, _offset} <- DateTime.from_iso8601(updated) do
      issue = %{
        "id" => id,
        "number" => number,
        "title" => title,
        "body" => text,
        "updated_at" => updated,
        "url" =>
          "#{GitHub.web_url(access.settings.github.api_url)}/#{access.repository.github_repository}/issues/#{number}"
      }

      with :ok <- CanonicalJSON.validate(issue, max_bytes: 48_000), do: {:ok, issue}
    else
      _unavailable -> {:error, :issue_unavailable}
    end
  end

  def digest(issue), do: CanonicalJSON.digest(issue)

  @doc "Comments and label changes do not change the report being triaged or approved."
  def content_digest(issue),
    do: issue |> Map.take(~w(id number title body url)) |> CanonicalJSON.digest()
end
