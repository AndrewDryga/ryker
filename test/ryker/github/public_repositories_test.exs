defmodule Ryker.GitHub.PublicRepositoriesTest do
  # tenantcorp/tenant-core vendors skypjack/entt, which no installation of the GitHub App
  # reaches (2026-10-03): whether such a repository is public decides whether its code is
  # fetched without credentials, and only GitHub not answering is worth another attempt.
  use ExUnit.Case, async: true

  alias Ryker.GitHub.PublicRepositories

  defmodule Answers do
    def request(_client, :get, "/repos/" <> slug, nil, _headers) do
      case slug do
        "skypjack/entt" ->
          {:ok, %{status: 200, headers: [], body: repository("skypjack/entt", 2, false)}}

        "acme/secret" ->
          {:ok, %{status: 200, headers: [], body: repository("acme/secret", 3, true)}}

        "acme/hidden" ->
          {:ok, %{status: 404, headers: [], body: %{"message" => "Not Found"}}}

        "acme/limited" ->
          {:ok, %{status: 403, headers: [], body: %{"message" => "API rate limit exceeded"}}}
      end
    end

    defp repository(name, id, private?),
      do: %{"full_name" => name, "id" => id, "private" => private?}
  end

  test "a public repository is named as GitHub spells it, and anything else is told apart" do
    lookup = &PublicRepositories.lookup("https://api.github.invalid", &1, "token", Answers)

    assert lookup.("skypjack/entt") == {:ok, %{full_name: "skypjack/entt", id: 2}}
    assert lookup.("acme/secret") == {:error, :not_public}
    assert lookup.("acme/hidden") == {:error, :not_public}
    assert lookup.("acme/limited") == {:error, {:github_api_error, 403}}
    assert lookup.("../outside") == {:error, :not_public}
  end
end
