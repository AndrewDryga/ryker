defmodule Responder.Settings.WebhookSource do
  @moduledoc "One inbound webhook source: preset or custom mapping, auth, destination and context."
  use Ecto.Schema
  import Ecto.Changeset
  alias Responder.Settings.Validation

  @primary_key {:name, :string, autogenerate: false}
  @fields ~w(name enabled adapter_kind auth_kind secret_name destination_transport destination_conversation_ref destination_thread_ref context_ref group_by_labels mapping publication_lifecycle)a
  @mapping_required ~w(event_id status title)
  @mapping_optional ~w(annotations ends_at incident_id item_id labels revision severity source_url starts_at summary)
  @lifecycle_fields ~w(environments kinds repositories targets)
  @lifecycle_kinds ~w(deployment terraform)

  schema "webhook_source_settings" do
    field(:enabled, :boolean, default: true)
    field(:adapter_kind, Ecto.Enum, values: [:universal, :grafana, :mapped_json])
    field(:auth_kind, Ecto.Enum, values: [:bearer, :hmac_sha256])
    field(:secret_name, :string)
    field(:destination_transport, :string)
    field(:destination_conversation_ref, :string)
    field(:destination_thread_ref, :string)
    field(:context_ref, :string)
    field(:group_by_labels, {:array, :string}, default: [])
    field(:mapping, :map)
    field(:publication_lifecycle, :map)
    timestamps(type: :utc_datetime_usec)
  end

  def fields, do: @fields
  def mapping_fields, do: {@mapping_required, @mapping_optional}
  def new(_snapshot), do: %__MODULE__{}
  def find(snapshot, :name, name), do: Enum.find(snapshot.webhook_sources, &(&1.name == name))

  def changeset(current, attributes, snapshot) do
    contexts = Enum.map(snapshot.repositories, & &1.ref) ++ Enum.map(snapshot.contexts, & &1.ref)

    current
    |> cast(attributes, @fields)
    |> validate_required([
      :name,
      :enabled,
      :adapter_kind,
      :auth_kind,
      :secret_name,
      :destination_transport,
      :destination_conversation_ref,
      :context_ref,
      :group_by_labels
    ])
    |> validate_format(:name, Validation.adapter_name_pattern())
    |> validate_format(:secret_name, Validation.secret_name_pattern())
    |> validate_inclusion(:destination_transport, ~w(slack github control_plane))
    |> validate_length(:destination_conversation_ref, min: 1, max: 1_024)
    |> validate_length(:destination_thread_ref, min: 1, max: 1_024)
    |> Validation.validate_known(:context_ref, contexts, :unknown_context)
    |> Validation.validate_unique_list(
      :group_by_labels,
      &(is_binary(&1) and byte_size(&1) in 1..256)
    )
    |> validate_length(:group_by_labels, max: 64)
    |> validate_mapping()
    |> validate_lifecycle(snapshot)
  end

  defp validate_mapping(changeset) do
    case {get_field(changeset, :adapter_kind), get_field(changeset, :mapping)} do
      {:mapped_json, %{} = mapping} ->
        mapping_error(changeset, mapping, Map.keys(mapping))

      {:mapped_json, _missing} ->
        add_error(changeset, :mapping, "is required for a custom mapping",
          validation: :mapping_required
        )

      {_preset, nil} ->
        changeset

      {_preset, _present} ->
        add_error(changeset, :mapping, "is only supported for a custom mapping",
          validation: :mapping_unsupported
        )
    end
  end

  defp mapping_error(changeset, mapping, keys) do
    cond do
      not Enum.all?(keys, &is_binary/1) or keys -- (@mapping_required ++ @mapping_optional) != [] ->
        add_error(changeset, :mapping, "has unknown fields", validation: :mapping_fields)

      @mapping_required -- keys != [] ->
        add_error(changeset, :mapping, "is missing required fields",
          validation: :mapping_required
        )

      not Enum.all?(mapping, fn {_key, value} -> bounded_path?(value) end) ->
        add_error(changeset, :mapping, "values must be bounded paths",
          validation: :mapping_values
        )

      true ->
        changeset
    end
  end

  defp bounded_path?(value),
    do: is_binary(value) and String.trim(value) != "" and byte_size(value) <= 1_024

  defp validate_lifecycle(changeset, snapshot) do
    case get_field(changeset, :publication_lifecycle) do
      nil -> changeset
      %{} = scope -> lifecycle_error(changeset, scope, Enum.map(snapshot.repositories, & &1.ref))
      _other -> add_error(changeset, :publication_lifecycle, "is invalid", validation: :lifecycle)
    end
  end

  defp lifecycle_error(changeset, scope, repositories) do
    valid =
      Map.keys(scope) |> Enum.sort() == @lifecycle_fields and
        Enum.all?(@lifecycle_fields, &bounded_scope?(scope[&1])) and
        Enum.all?(scope["kinds"], &(&1 in @lifecycle_kinds)) and
        Enum.all?(scope["repositories"], &(&1 in repositories))

    if valid,
      do: changeset,
      else: add_error(changeset, :publication_lifecycle, "is invalid", validation: :lifecycle)
  end

  defp bounded_scope?(values) do
    is_list(values) and values != [] and length(values) <= 64 and Enum.uniq(values) == values and
      Enum.all?(values, &(is_binary(&1) and byte_size(&1) in 1..256))
  end

  def deletable(_source, _snapshot), do: :ok
end
