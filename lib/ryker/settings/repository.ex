defmodule Ryker.Settings.Repository do
  @moduledoc "A connected repository: display metadata, base branch and publication checkout."
  use Ecto.Schema
  import Ecto.Changeset
  alias Ryker.Settings.Validation

  @primary_key {:ref, :string, autogenerate: false}
  @fields ~w(ref display_name description github_repository base_branch publication_checkout_path)a

  schema "repository_settings" do
    field(:display_name, :string)
    field(:description, :string)
    field(:github_repository, :string)
    field(:base_branch, :string, default: "main")
    field(:publication_checkout_path, :string)
    timestamps(type: :utc_datetime_usec)
  end

  def fields, do: @fields
  def new(_snapshot), do: %__MODULE__{}
  def find(snapshot, :ref, ref), do: Enum.find(snapshot.repositories, &(&1.ref == ref))

  def changeset(current, attributes, snapshot) do
    contexts = Enum.map(snapshot.contexts, & &1.ref)

    current
    |> cast(attributes, @fields)
    |> validate_required([:ref, :base_branch])
    |> Validation.validate_reference(:ref)
    |> validate_exclusion(:ref, contexts)
    |> validate_length(:display_name, min: 1, max: 120)
    |> validate_length(:description, min: 1, max: 1_000)
    |> validate_format(:github_repository, Validation.github_repository_pattern())
    |> Validation.validate_git_ref(:base_branch)
    |> Validation.validate_absolute_path(:publication_checkout_path)
  end

  def deletable(repository, snapshot) do
    referenced =
      Enum.any?(
        snapshot.contexts,
        &(&1.primary_repository_ref == repository.ref or
            repository.ref in &1.read_only_repository_refs)
      ) or
        Enum.any?(snapshot.github_bindings, &(&1.repository_ref == repository.ref)) or
        Enum.any?(
          snapshot.policy_bindings,
          &(&1.scope_kind == :repository and &1.scope_ref == repository.ref)
        ) or
        Enum.any?(snapshot.webhook_sources, &(&1.context_ref == repository.ref)) or
        snapshot.slack.default_repository_ref == repository.ref

    if referenced, do: {:error, [{:ref, :referenced}]}, else: :ok
  end
end
