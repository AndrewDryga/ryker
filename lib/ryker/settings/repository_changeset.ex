defmodule Ryker.Settings.RepositoryChangeset do
  @moduledoc "Adding a repository and changing a saved one (`Ryker.Settings.Repository`)."
  @behaviour Ryker.Settings.SectionChangeset

  import Ecto.Changeset
  alias Ryker.Settings.{Repository, Validation}

  @fields ~w(
    ref display_name description github_repository base_branch
    github_access onboarding_state onboarding_error source_commit
  )a

  @impl true
  def fields, do: @fields

  @impl true
  def insert(attributes, _snapshot), do: %Repository{} |> cast(attributes, @fields) |> changeset()

  @impl true
  def update(%Repository{} = repository, attributes, _snapshot),
    do: repository |> cast(attributes, @fields) |> changeset()

  defp changeset(changeset) do
    changeset
    |> validate_required([:ref, :base_branch])
    |> Validation.validate_reference(:ref)
    |> validate_length(:display_name, min: 1, max: 120)
    |> validate_length(:description, min: 1, max: 1_000)
    |> validate_format(:github_repository, Validation.github_repository_pattern())
    |> Validation.validate_git_ref(:base_branch)
    |> validate_length(:onboarding_error, max: 1_024)
    |> validate_format(:source_commit, ~r/\A[0-9a-f]{40}\z/)
    |> check_constraint(:github_access, name: :repository_github_state_valid)
  end
end
