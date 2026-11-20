defmodule Ryker.GitHub.GraphQL do
  @moduledoc "Bounded GraphQL requests using the configured GitHub API origin."
  alias Ryker.Delivery

  def request(http, query, variables, options \\ []) do
    requester = Keyword.get(options, :requester, Delivery.JSONClient)
    base = String.trim_trailing(http.base_url, "/api/v3")

    path =
      if String.starts_with?(URI.parse(base).host, "api."), do: "/graphql", else: "/api/graphql"

    response =
      requester.request(
        %{http | base_url: base},
        :post,
        path,
        %{"query" => query, "variables" => variables},
        [{"accept", "application/json"}]
      )

    case response do
      {:ok, %{status: 200, body: %{"errors" => errors}}} when is_list(errors) ->
        if Enum.any?(errors, &forbidden?/1),
          do: {:error, :github_forbidden},
          else: {:error, :github_unavailable}

      {:ok, %{status: 200, body: %{"data" => data} = body}}
      when is_map(data) and not is_map_key(body, "errors") ->
        {:ok, data}

      _invalid ->
        {:error, :github_unavailable}
    end
  end

  defp forbidden?(%{"type" => type}), do: type == "FORBIDDEN"
  defp forbidden?(_error), do: false
end
