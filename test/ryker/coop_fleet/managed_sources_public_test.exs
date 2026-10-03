defmodule Ryker.CoopFleet.ManagedSourcesPublicTest do
  # theblitzapp/blitz-core vendors skypjack/entt, which no installation of the GitHub App
  # reaches, so Ryker could not work on blitz-core at all, nor on any task in an environment
  # that listed it (2026-10-03). A public repository Ryker was never given is fetched without
  # credentials; one that is not public, or that Ryker was given but cannot reach, stays refused.
  use ExUnit.Case, async: true

  alias Ryker.CoopFleet.ManagedSources

  @snapshot %{
    repositories: [
      %{ref: "acme-suspended", github_repository: "acme/suspended", github_access: :suspended}
    ],
    github_bindings: []
  }

  test "a submodule from a public repository Ryker was never given is read without credentials" do
    public = fn "SkypJack/EnTT" -> {:ok, %{full_name: "skypjack/entt", id: 2}} end

    assert ManagedSources.resolve_repository(@snapshot, "SkypJack/EnTT", public) ==
             {:ok,
              %{
                repository_ref: "public:skypjack:entt",
                github_repository: "skypjack/entt",
                repository_id: 2,
                remote: "https://github.com/skypjack/entt.git",
                token: nil
              }}

    assert ManagedSources.resolve_repository(@snapshot, "acme/secret", fn _ ->
             {:error, :not_public}
           end) == {:error, :submodule_not_configured}

    assert ManagedSources.resolve_repository(@snapshot, "acme/slow", fn _ ->
             {:error, {:github_api_error, 503}}
           end) == {:error, :submodule_not_authorized}

    # Given to Ryker, its access is Ryker's to fix: GitHub is not asked instead.
    assert ManagedSources.resolve_repository(@snapshot, "acme/suspended", fn _ ->
             flunk("looked up a repository Ryker was given")
           end) == {:error, :submodule_not_configured}
  end
end
