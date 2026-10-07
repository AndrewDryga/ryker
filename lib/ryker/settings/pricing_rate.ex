defmodule Ryker.Settings.PricingRate do
  @moduledoc "Optional versioned USD per-million-token estimate rates; reported cost stays authoritative."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

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

  @type t :: %__MODULE__{}
end
