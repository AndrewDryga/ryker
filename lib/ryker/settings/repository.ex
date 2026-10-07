defmodule Ryker.Settings.Repository do
  @moduledoc "A connected repository: display metadata and the base branch supplied to Coop."
  use Ecto.Schema
  import Ecto.Changeset
  alias Ryker.Settings.Validation

  @primary_key {:ref, :string, autogenerate: false}
  @fields ~w(
    ref display_name description github_repository base_branch
    github_access onboarding_state onboarding_error source_commit
  )a

  schema "repository_settings" do
    field(:display_name, :string)
    field(:description, :string)
    field(:github_repository, :string)
    field(:base_branch, :string, default: "main")

    field(:github_access, Ecto.Enum,
      values: [:available, :suspended, :removed],
      default: :available
    )

    field(:onboarding_state, Ecto.Enum,
      values: [:pending, :cloning, :ready, :blocked],
      default: :pending
    )

    field(:onboarding_error, :string)
    field(:source_commit, :string)
    timestamps(type: :utc_datetime_usec)
  end

  def fields, do: @fields
  def new(_snapshot), do: %__MODULE__{}
  def find(snapshot, :ref, ref), do: Enum.find(snapshot.repositories, &(&1.ref == ref))

  def changeset(current, attributes, _snapshot) do
    current
    |> cast(attributes, @fields)
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
