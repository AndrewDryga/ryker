defmodule Ryker.Settings.RepositoryContext do
  @moduledoc "A logical context: one primary repository plus read-only companions."
  use Ecto.Schema
  import Ecto.Changeset
  alias Ryker.Settings.Validation

  @primary_key {:ref, :string, autogenerate: false}
  @fields ~w(ref display_name primary_repository_ref read_only_repository_refs parallel_goal_limit)a

  schema "repository_context_settings" do
    field(:display_name, :string)
    field(:primary_repository_ref, :string)
    field(:read_only_repository_refs, {:array, :string}, default: [])
    field(:parallel_goal_limit, :integer, default: 3)
    timestamps(type: :utc_datetime_usec)
  end

  def fields, do: @fields
  def new(_snapshot), do: %__MODULE__{}
  def find(snapshot, :ref, ref), do: Enum.find(snapshot.contexts, &(&1.ref == ref))

  def changeset(current, attributes, snapshot) do
    repositories = Enum.map(snapshot.repositories, & &1.ref)

    changeset =
      current
      |> cast(attributes, @fields)
      |> validate_required([
        :ref,
        :primary_repository_ref,
        :read_only_repository_refs,
        :parallel_goal_limit
      ])
      |> Validation.validate_reference(:ref)
      |> validate_exclusion(:ref, repositories)
      |> validate_length(:display_name, min: 1, max: 120)
      |> Validation.validate_known(:primary_repository_ref, repositories, :unknown_repository)
      |> Validation.validate_unique_list(:read_only_repository_refs, &(&1 in repositories))
      |> validate_length(:read_only_repository_refs, max: 32)
      |> validate_inclusion(:parallel_goal_limit, 1..3)

    primary = get_field(changeset, :primary_repository_ref)
    companions = get_field(changeset, :read_only_repository_refs) || []

    if primary in companions,
      do:
        add_error(changeset, :read_only_repository_refs, "must exclude the primary",
          validation: :primary_companion
        ),
      else: changeset
  end

  def deletable(context, snapshot) do
    referenced =
      Enum.any?(snapshot.github_bindings, &(&1.repository_context_ref == context.ref)) or
        Enum.any?(
          snapshot.policy_bindings,
          &(&1.scope_kind == :context and &1.scope_ref == context.ref)
        ) or
        Enum.any?(snapshot.webhook_sources, &(&1.context_ref == context.ref))

    if referenced, do: {:error, [{:ref, :referenced}]}, else: :ok
  end
end
