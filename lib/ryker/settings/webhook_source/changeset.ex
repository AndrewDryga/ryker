defmodule Ryker.Settings.WebhookSource.Changeset do
  @moduledoc "Adding a webhook source and changing a saved one (`Ryker.Settings.WebhookSource`)."
  @behaviour Ryker.Settings.Section.Changeset
  use Ryker, :changeset
  alias Ryker.Publication
  alias Ryker.Settings.{Validation, WebhookSource}
  alias Ryker.Webhooks

  @fields ~w(name enabled adapter_kind auth_kind secret_name destination_transport destination_conversation_ref destination_thread_ref environment_ref group_by_labels mapping publication_lifecycle)a
  # A saved source becomes a route (`Ryker.Webhooks.Route`), so it may name
  # only what a route takes, spelled as the saved map spells it.
  @mapping_fields Enum.map(Webhooks.Route.mapping_fields(), &Atom.to_string/1)
  @mapping_required Enum.map(Webhooks.Route.required_mapping_fields(), &Atom.to_string/1)
  @lifecycle_fields Webhooks.Route.lifecycle_fields()
                    |> Enum.map(&Atom.to_string/1)
                    |> Enum.sort()

  @impl true
  def fields, do: @fields

  @impl true
  def insert(attributes, snapshot),
    do: %WebhookSource{} |> cast(attributes, @fields) |> changeset(snapshot)

  @impl true
  def update(%WebhookSource{} = source, attributes, snapshot),
    do: source |> cast(attributes, @fields) |> changeset(snapshot)

  defp changeset(changeset, snapshot) do
    environments = Enum.map(snapshot.environments, & &1.ref)

    changeset
    |> validate_required([
      :name,
      :enabled,
      :adapter_kind,
      :auth_kind,
      :secret_name,
      :destination_transport,
      :destination_conversation_ref,
      :environment_ref,
      :group_by_labels
    ])
    |> validate_format(:name, Validation.adapter_name_pattern())
    |> validate_format(:secret_name, Validation.secret_name_pattern())
    # A transport is the string every inbox entry, request and publication
    # names its destination with; an enum here would be the one place it is
    # an atom.
    # credo:disable-for-next-line Ryker.Checks.EnumOverValidateInclusion
    |> validate_inclusion(:destination_transport, ~w(slack github control_plane))
    |> validate_length(:destination_conversation_ref, min: 1, max: 1_024, count: :codepoints)
    |> validate_length(:destination_thread_ref, min: 1, max: 1_024, count: :codepoints)
    |> Validation.validate_known(:environment_ref, environments, :unknown_environment)
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
      not Enum.all?(keys, &is_binary/1) or keys -- @mapping_fields != [] ->
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
        Enum.all?(scope["kinds"], &(&1 in Publication.DeploymentSignal.kinds())) and
        Enum.all?(scope["repositories"], &(&1 in repositories))

    if valid,
      do: changeset,
      else: add_error(changeset, :publication_lifecycle, "is invalid", validation: :lifecycle)
  end

  defp bounded_scope?(values) do
    is_list(values) and values != [] and length(values) <= 64 and Enum.uniq(values) == values and
      Enum.all?(values, &(is_binary(&1) and byte_size(&1) in 1..256))
  end
end
