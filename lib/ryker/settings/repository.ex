defmodule Ryker.Settings.Repository do
  @moduledoc "A connected repository: display metadata and the base branch supplied to Coop."
  use Ryker, :schema

  @primary_key {:ref, :string, autogenerate: false}

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
    timestamps()
  end

  @type t :: %__MODULE__{}
end
