defmodule Ryker.CoopFleet.ModelBucket do
  @moduledoc false
  use Ryker, :schema

  @primary_key {:id, :string, autogenerate: false}
  schema "coop_model_buckets" do
    field(:concurrency, :integer, default: 1)
    field(:blocked_until, :utc_datetime_usec)
    field(:updated_by, :string)
    timestamps()
  end
end
