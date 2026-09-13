defmodule Ryker.Settings.PricingRate do
  @moduledoc "Optional versioned USD per-million-token estimate rates; reported cost stays authoritative."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @fields ~w(id execution_target input_usd_per_million cached_input_usd_per_million output_usd_per_million reasoning_usd_per_million effective_from provenance)a
  @maximum Decimal.new(100_000)

  schema "pricing_rates" do
    field(:execution_target, :string)
    field(:input_usd_per_million, :decimal)
    field(:cached_input_usd_per_million, :decimal)
    field(:output_usd_per_million, :decimal)
    field(:reasoning_usd_per_million, :decimal)
    field(:effective_from, :date)
    field(:revision, :integer)
    field(:provenance, :string)
    field(:inserted_at, :utc_datetime_usec)
  end

  def fields, do: @fields

  def new(snapshot),
    do: %__MODULE__{
      id: Ecto.UUID.generate(),
      revision: snapshot.installation.revision + 1,
      inserted_at: DateTime.utc_now()
    }

  def find(snapshot, :id, id) when is_binary(id),
    do: Enum.find(snapshot.pricing_rates, &(&1.id == id))

  def find(_snapshot, :id, _id), do: nil

  def changeset(current, attributes, snapshot) do
    changeset =
      current
      |> cast(attributes, @fields -- [:id])
      |> validate_required([
        :execution_target,
        :input_usd_per_million,
        :cached_input_usd_per_million,
        :output_usd_per_million,
        :effective_from,
        :provenance
      ])
      |> validate_format(:execution_target, ~r/\A[a-z0-9][a-z0-9._:-]{0,255}\z/)
      |> validate_length(:provenance, min: 1, max: 1_024)

    changeset =
      Enum.reduce(
        ~w(input_usd_per_million cached_input_usd_per_million output_usd_per_million reasoning_usd_per_million)a,
        changeset,
        &validate_number(&2, &1, greater_than_or_equal_to: 0, less_than_or_equal_to: @maximum)
      )

    # A changed rate is a new versioned row; an edited row keeps its version.
    changeset =
      if current.revision,
        do: changeset,
        else: put_change(changeset, :revision, snapshot.installation.revision + 1)

    duplicate =
      Enum.any?(snapshot.pricing_rates, fn rate ->
        rate.id != current.id and rate.execution_target == get_field(changeset, :execution_target) and
          rate.effective_from == get_field(changeset, :effective_from)
      end)

    if duplicate,
      do:
        add_error(changeset, :effective_from, "already has a rate for this target",
          validation: :already_bound
        ),
      else: changeset
  end

  def deletable(_rate, _snapshot), do: :ok
end
