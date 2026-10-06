defmodule Ryker.Publication.GitHubStatusTest do
  use ExUnit.Case, async: true
  alias Ryker.Publication.GitHubStatus

  defmodule API do
    def get_publication_status(client, repository, number),
      do: {:ok, {client, repository, number}}
  end

  test "status uses the exact repository client and refuses ambiguous bindings" do
    first = %{api: API, client: :first, github_repository: "acme/first"}
    second = %{api: API, client: :second, github_repository: "acme/second"}
    binding = %{repositories: %{"first" => first, "second" => second}}

    assert GitHubStatus.get_publication_status(binding, "acme/second", 42) ==
             {:ok, {:second, "acme/second", 42}}

    ambiguous = put_in(binding, [:repositories, "duplicate"], %{second | client: :other})
    assert {:error, _} = GitHubStatus.get_publication_status(ambiguous, "acme/second", 42)
    assert {:error, _} = GitHubStatus.get_publication_status(binding, "acme/missing", 42)
  end
end
