defmodule Ryker.GitHub.ReviewReply do
  @moduledoc "Verifies that a review reply addresses this App's comment on the bound pull request."
  alias Ryker.Delivery
  alias Ryker.GitHub
  alias Ryker.GitHub.Binding

  @headers [
    {"accept", "application/vnd.github+json"},
    {"x-github-api-version", "2022-11-28"}
  ]

  @spec check(Binding.t(), map(), term(), keyword()) :: {:ok, boolean()} | {:error, term()}
  def check(binding, payload, http, options \\ [])

  def check(
        %Binding{} = binding,
        %{"comment" => %{"in_reply_to_id" => id}, "pull_request" => %{"number" => number}},
        http,
        options
      ) do
    if GitHub.id?(id) and GitHub.id?(number) do
      requester = Keyword.get(options, :requester, Delivery.JSONClient)
      path = "/repos/#{binding.repository_full_name}/pulls/comments/#{id}"
      subject = "#{GitHub.api_url()}repos/#{binding.repository_full_name}/pulls/#{number}"

      result(
        requester.request(http, :get, path, nil, @headers),
        binding.ryker_actor_id,
        id,
        subject
      )
    else
      {:ok, false}
    end
  end

  def check(_binding, _payload, _http, _options), do: {:ok, false}

  defp result(
         {:ok,
          %{
            status: 200,
            body: %{
              "id" => id,
              "pull_request_url" => subject,
              "user" => %{"id" => actor, "type" => "Bot"}
            }
          }},
         actor,
         id,
         subject
       ),
       do: {:ok, true}

  defp result({:ok, %{status: status}}, _actor, _id, _subject) when status in [200, 404],
    do: {:ok, false}

  defp result({:error, reason}, _actor, _id, _subject), do: unavailable(reason)

  defp result({:ok, %{status: status}}, _actor, _id, _subject),
    do: unavailable({:http_status, status})

  defp result(_response, _actor, _id, _subject), do: unavailable(:response)

  defp unavailable(reason), do: {:error, {:github_review_reply_unavailable, reason}}
end
