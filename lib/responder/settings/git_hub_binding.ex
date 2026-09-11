defmodule Responder.Settings.GitHubBinding do
  @moduledoc "Exact verified GitHub installation identity for one connected repository."
  use Ecto.Schema
  import Ecto.Changeset
  alias Responder.Settings.Validation

  @primary_key {:name, :string, autogenerate: false}
  @fields ~w(name repository_ref installation_id repository_id responder_actor_id authorized_actor_ids repository_context_ref)a

  schema "github_binding_settings" do
    field(:repository_ref, :string)
    field(:installation_id, :integer)
    field(:repository_id, :integer)
    field(:responder_actor_id, :integer)
    field(:authorized_actor_ids, {:array, :integer})
    field(:repository_context_ref, :string)
    timestamps(type: :utc_datetime_usec)
  end

  def fields, do: @fields
  def new(_snapshot), do: %__MODULE__{}
  def find(snapshot, :name, name), do: Enum.find(snapshot.github_bindings, &(&1.name == name))

  def changeset(current, attributes, snapshot) do
    repositories = Enum.map(snapshot.repositories, & &1.ref)

    changeset =
      current
      |> cast(attributes, @fields)
      |> validate_required([
        :name,
        :repository_ref,
        :installation_id,
        :repository_id,
        :responder_actor_id,
        :authorized_actor_ids
      ])
      |> validate_format(:name, Validation.adapter_name_pattern())
      |> Validation.validate_known(:repository_ref, repositories, :unknown_repository)
      |> validate_number(:installation_id, greater_than: 0)
      |> validate_number(:repository_id, greater_than: 0)
      |> validate_number(:responder_actor_id, greater_than: 0)
      |> Validation.validate_unique_list(:authorized_actor_ids, &(is_integer(&1) and &1 > 0))
      |> validate_length(:authorized_actor_ids, min: 1, max: 256)
      |> unique_constraint(:repository_ref, name: :github_binding_settings_repository_ref_index)

    context_ref = get_field(changeset, :repository_context_ref)
    repository_ref = get_field(changeset, :repository_ref)

    other_bindings =
      Enum.reject(snapshot.github_bindings, &(&1.name == get_field(changeset, :name)))

    cond do
      Enum.any?(other_bindings, &(&1.repository_ref == repository_ref)) ->
        add_error(changeset, :repository_ref, "is already bound", validation: :already_bound)

      is_nil(context_ref) ->
        changeset

      not Enum.any?(
        snapshot.contexts,
        &(&1.ref == context_ref and &1.primary_repository_ref == repository_ref)
      ) ->
        add_error(
          changeset,
          :repository_context_ref,
          "must be a context whose primary is this repository",
          validation: :context_primary
        )

      true ->
        changeset
    end
  end

  def deletable(_binding, _snapshot), do: :ok
end
