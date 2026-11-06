defmodule Ryker.GitHub.RepositoryAccess do
  @moduledoc "Checks the webhook sender's effective access to the bound repository."
  alias Ryker.Delivery
  alias Ryker.GitHub.Binding

  @headers [
    {"accept", "application/vnd.github+json"},
    {"x-github-api-version", "2022-11-28"}
  ]

  @spec authorize(Binding.t(), map(), term(), keyword()) :: :ok | {:error, term()}
  def authorize(binding, payload, http, options \\ [])

  def authorize(%Binding{} = binding, payload, http, options) when is_map(payload) do
    requester = Keyword.get(options, :requester, Delivery.JSONClient)

    with {:ok, login} <- sender_login(payload),
         path <- permission_path(binding.repository_full_name, login),
         response <- requester.request(http, :get, path, nil, @headers) do
      permission(response, Keyword.get(options, :minimum_role, :write))
    end
  rescue
    error -> unavailable(error)
  end

  def authorize(_binding, _payload, _http, _options),
    do: {:error, :actor_not_authorized}

  defp sender_login(%{"sender" => %{"login" => login, "type" => type}})
       when is_binary(login) and type in ["User", "Bot"] and byte_size(login) in 1..256,
       do: {:ok, login}

  defp sender_login(_payload), do: {:error, :actor_not_authorized}

  defp permission({:ok, %{body: body, status: 200}}, minimum_role) when is_map(body) do
    if permitted?(body, minimum_role), do: :ok, else: {:error, :actor_not_authorized}
  end

  defp permission({:ok, %{status: status}}, _minimum_role) when status in [200, 404],
    do: {:error, :actor_not_authorized}

  defp permission({:ok, %{status: status}}, _minimum_role) when is_integer(status),
    do: unavailable({:http_status, status})

  defp permission({:error, reason}, _minimum_role), do: unavailable(reason)
  defp permission(_response, _minimum_role), do: unavailable(:response)

  defp permitted?(body, :write), do: body["permission"] in ["write", "admin"]

  # GitHub's legacy permission field collapses Maintain into Write. Custom
  # roles keep their own name, so also honor their effective base permissions.
  defp permitted?(body, :maintain) do
    body["permission"] == "admin" or body["role_name"] in ["maintain", "admin"] or
      get_in(body, ["user", "permissions", "maintain"]) == true or
      get_in(body, ["user", "permissions", "admin"]) == true
  end

  defp permitted?(_body, _minimum_role), do: false

  defp permission_path(repository, login) do
    "/repos/#{repository}/collaborators/#{segment(login)}/permission"
  end

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp unavailable(reason),
    do: {:error, {:github_repository_access_unavailable, reason}}
end
