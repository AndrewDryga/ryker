defmodule Ryker.Settings.PricingRate.Changeset do
  @moduledoc """
  Adding a price and changing a saved one (`Ryker.Settings.PricingRate`). A
  new price is a row of its own, versioned at the revision that adds it; a
  changed one keeps its version.
  """
  @behaviour Ryker.Settings.Section.Changeset
  use Ryker, :changeset
  alias Ryker.Settings.PricingRate

  @fields ~w(id execution_target input_usd_per_million cached_input_usd_per_million output_usd_per_million reasoning_usd_per_million effective_from provenance)a
  # A save names a saved price by `id`; it never writes one.
  @writable_fields @fields -- [:id]
  @rates ~w(input_usd_per_million cached_input_usd_per_million output_usd_per_million reasoning_usd_per_million)a
  @maximum Decimal.new(100_000)
  @execution_target ~r/\A[a-z0-9][a-z0-9._-]*:[a-z0-9._-]+\z/

  @impl true
  def fields, do: @fields

  @impl true
  def insert(attributes, snapshot) do
    %PricingRate{revision: snapshot.installation.revision + 1}
    |> cast(attributes, @writable_fields)
    |> changeset(snapshot)
  end

  @impl true
  def update(%PricingRate{} = rate, attributes, snapshot),
    do: rate |> cast(attributes, @writable_fields) |> changeset(snapshot)

  defp changeset(changeset, snapshot) do
    changeset =
      changeset
      |> validate_required([
        :execution_target,
        :input_usd_per_million,
        :cached_input_usd_per_million,
        :output_usd_per_million,
        :effective_from,
        :provenance
      ])
      # A price covers work by its provider and model, the way every execution
      # names its model, so it needs both and exactly one colon between them.
      |> validate_format(:execution_target, @execution_target)
      |> validate_length(:execution_target, max: 256, count: :codepoints)
      |> validate_length(:provenance, min: 1, max: 1_024, count: :codepoints)
      |> validate_rates()

    if duplicate?(changeset, snapshot.pricing_rates) do
      add_error(changeset, :effective_from, "already has a rate for this target",
        validation: :already_bound
      )
    else
      changeset
    end
  end

  defp validate_rates(changeset) do
    Enum.reduce(
      @rates,
      changeset,
      &validate_number(&2, &1, greater_than_or_equal_to: 0, less_than_or_equal_to: @maximum)
    )
  end

  defp duplicate?(changeset, rates) do
    target = get_field(changeset, :execution_target)
    effective_from = get_field(changeset, :effective_from)

    Enum.any?(rates, fn rate ->
      rate.id != changeset.data.id and rate.execution_target == target and
        rate.effective_from == effective_from
    end)
  end
end
