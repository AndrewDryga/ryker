defmodule Ryker.GitHub.PublicRepositories do
  @moduledoc """
  Whether a GitHub repository Ryker was never given is public, and its id.

  A repository Ryker works on may vendor code from a repository outside every
  organization its GitHub App is installed in: tenantcorp/tenant-core vendors
  skypjack/entt (2026-10-03). Anyone may read a public repository, so its code
  is fetched without credentials. GitHub is asked for its id and visibility
  with the installation token of the repository that vendors it, since any
  token may read a public repository.
  """
  alias Ryker.Config
  alias Ryker.CoopFleet.JobSpec
  alias Ryker.Delivery.JSONClient

  @headers [
    {"accept", "application/vnd.github+json"},
    {"user-agent", "ryker"},
    {"x-github-api-version", "2022-11-28"}
  ]

  @doc """
  The public repository `slug` names, as GitHub spells it. One GitHub does
  not show, or shows as private, is `:not_public`: no retry fetches it. Any
  other failure is GitHub not answering, which a later attempt may get past.
  """
  @spec lookup(String.t(), String.t(), String.t(), module()) ::
          {:ok, %{full_name: String.t(), id: pos_integer()}}
          | {:error, :not_public}
          | {:error, term()}
  def lookup(api_url, slug, token, requester \\ requester()) do
    with true <- JobSpec.github_repository?(slug),
         {:ok, client} <-
           JSONClient.new(%{
             base_url: api_url,
             finch: Ryker.CoopFinch,
             receive_timeout: 30_000,
             token_provider: fn -> {:ok, token} end
           }),
         {:ok, %{status: status, body: body}} <-
           requester.request(client, :get, "/repos/" <> slug, nil, @headers) do
      public(status, body)
    else
      false -> {:error, :not_public}
      {:error, _reason} = error -> error
    end
  end

  defp public(200, %{"full_name" => name, "id" => id, "private" => false})
       when is_binary(name) and is_integer(id) and id > 0 do
    if JobSpec.github_repository?(name),
      do: {:ok, %{full_name: name, id: id}},
      else: {:error, {:github_protocol_error, :repository}}
  end

  defp public(status, _body) when status in [200, 404], do: {:error, :not_public}
  defp public(status, _body), do: {:error, {:github_api_error, status}}

  # GitHub itself; in tests, the replies each test records.
  defp requester, do: Config.get_env(:github_public_requester, JSONClient)
end
