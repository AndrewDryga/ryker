defmodule Ryker.Flywheel.Receipt do
  @moduledoc "An analyzed source record version; never a human rating or a copy of source content."
  use Ryker, :schema
  alias Ryker.Flywheel.Run

  schema "flywheel_receipts" do
    field(:source, :string)
    field(:ref, :string)
    field(:version, :string)
    belongs_to(:run, Run)
    field(:reviewed_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
