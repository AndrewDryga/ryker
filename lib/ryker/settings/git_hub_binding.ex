defmodule Ryker.Settings.GitHubBinding do
  @moduledoc "Exact verified GitHub installation identity for one connected repository."
  use Ecto.Schema
  import Ecto.Changeset
  alias Ryker.Settings.Validation

  @primary_key {:name, :string, autogenerate: false}
  @action_grants ~w(read review open_pull_request update_ryker_branch rerun_ci cancel_ci issues approve merge)
  @fields ~w(name repository_ref installation_id repository_id ryker_actor_id action_grants granted_permissions)a

  schema "github_binding_settings" do
    field(:repository_ref, :string)
    field(:installation_id, :integer)
    field(:repository_id, :integer)
    field(:ryker_actor_id, :integer)

    field(:action_grants, {:array, :string},
      default: ~w(read review open_pull_request update_ryker_branch rerun_ci)
    )

    field(:granted_permissions, :map, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  def fields, do: @fields
  def action_grants, do: @action_grants
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
        :ryker_actor_id
      ])
      |> validate_format(:name, Validation.adapter_name_pattern())
      |> Validation.validate_known(:repository_ref, repositories, :unknown_repository)
      |> validate_number(:installation_id, greater_than: 0)
      |> validate_number(:repository_id, greater_than: 0)
      |> validate_number(:ryker_actor_id, greater_than: 0)
      |> Validation.validate_unique_list(:action_grants, &(&1 in @action_grants))
      |> validate_length(:action_grants, min: 1, max: length(@action_grants))
      |> validate_change(:granted_permissions, &validate_permissions/2)
      |> check_constraint(:granted_permissions, name: :github_binding_permissions_valid)
      |> unique_constraint(:repository_ref, name: :github_binding_settings_repository_ref_index)

    repository_ref = get_field(changeset, :repository_ref)

    other_bindings =
      Enum.reject(snapshot.github_bindings, &(&1.name == get_field(changeset, :name)))

    if Enum.any?(other_bindings, &(&1.repository_ref == repository_ref)),
      do: add_error(changeset, :repository_ref, "is already bound", validation: :already_bound),
      else: changeset
  end

  def deletable(_binding, _snapshot), do: :ok

  defp validate_permissions(:granted_permissions, permissions) when is_map(permissions) do
    valid =
      map_size(permissions) <= 64 and
        Enum.all?(permissions, fn {name, level} ->
          is_binary(name) and byte_size(name) in 1..64 and
            level in ["read", "write", "admin"]
        end)

    if valid, do: [], else: [granted_permissions: "contain an invalid permission"]
  end

  defp validate_permissions(:granted_permissions, _permissions),
    do: [granted_permissions: "must be a permission map"]
end
