defmodule Ryker.Settings.EmisarBinding do
  @moduledoc "A trusted repository, context, or installation-purpose route to Emisar."

  use Ecto.Schema
  import Ecto.Changeset

  alias Ryker.Settings.Validation

  @primary_key {:id, :binary_id, autogenerate: false}
  @fields ~w(id scope_kind scope_ref purpose connection_ref)a
  @purposes [:conversation, :standard, :deep, :contributor, :incident, :schedule, :learning]

  schema "emisar_connection_bindings" do
    field(:scope_kind, Ecto.Enum, values: [:repository, :context, :installation_purpose])
    field(:scope_ref, :string)
    field(:purpose, Ecto.Enum, values: @purposes)

    belongs_to(:connection, Ryker.Settings.EmisarConnection,
      references: :ref,
      foreign_key: :connection_ref,
      type: :string
    )

    timestamps(type: :utc_datetime_usec)
  end

  def fields, do: @fields
  def purposes, do: @purposes
  def new(_snapshot), do: %__MODULE__{id: Ecto.UUID.generate()}

  def find(snapshot, :id, id),
    do: Enum.find(snapshot.emisar_bindings, &(&1.id == id))

  def changeset(current, attributes, snapshot) do
    changeset =
      current
      |> cast(attributes, @fields -- [:id])
      |> validate_required([:scope_kind, :scope_ref, :purpose, :connection_ref])
      |> validate_length(:scope_ref, min: 1, max: 256)
      |> Validation.validate_known(
        :connection_ref,
        Enum.map(snapshot.emisar_connections, & &1.ref),
        :unknown_connection
      )
      |> validate_scope(snapshot)

    duplicate =
      Enum.any?(snapshot.emisar_bindings, fn binding ->
        binding.id != current.id and binding.scope_kind == get_field(changeset, :scope_kind) and
          binding.scope_ref == get_field(changeset, :scope_ref) and
          binding.purpose == get_field(changeset, :purpose)
      end)

    if duplicate,
      do: add_error(changeset, :scope_ref, "is already bound for this purpose"),
      else: changeset
  end

  def deletable(_binding, _snapshot), do: :ok

  defp validate_scope(changeset, snapshot) do
    kind = get_field(changeset, :scope_kind)
    ref = get_field(changeset, :scope_ref)
    purpose = get_field(changeset, :purpose)

    valid? =
      case kind do
        :repository -> Enum.any?(snapshot.repositories, &(&1.ref == ref))
        :context -> Enum.any?(snapshot.contexts, &(&1.ref == ref))
        :installation_purpose -> ref == Atom.to_string(purpose)
        _ -> false
      end

    if valid?, do: changeset, else: add_error(changeset, :scope_ref, "is not a known scope")
  end
end
