defmodule Ryker.GitHub.GraphQL do
  @moduledoc "Bounded GraphQL requests using the configured GitHub API origin."
  alias Ryker.Delivery

  def request(http, query, variables, options \\ []) do
    requester = Keyword.get(options, :requester, Delivery.JSONClient)
    base = String.trim_trailing(http.base_url, "/api/v3")

    path =
      if String.starts_with?(URI.parse(base).host, "api."), do: "/graphql", else: "/api/graphql"

    with {:ok, %{status: 200, body: %{"data" => data} = body}} <-
           requester.request(
             %{http | base_url: base},
             :post,
             path,
             %{"query" => query, "variables" => variables},
             [{"accept", "application/json"}]
           ),
         false <- Map.has_key?(body, "errors"),
         true <- is_map(data),
         do: {:ok, data},
         else: (_error -> {:error, :github_unavailable})
  end
end
