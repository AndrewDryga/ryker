defmodule Ryker.Flywheel.Run do
  @moduledoc "One bounded improvement pass, with per-source coverage and a renewable operator lease."
  use Ryker, :schema

  schema "flywheel_runs" do
    field(:request_ref, :string)
    field(:mode, Ecto.Enum, values: [:suggest, :auto])
    field(:status, Ecto.Enum, values: [:running, :complete, :partial], default: :running)
    field(:starts_at, :utc_datetime_usec)
    field(:ends_at, :utc_datetime_usec)
    field(:progress, :map, default: %{})
    field(:policy, :map, default: %{})
    field(:lease_ref, Ecto.UUID)
    field(:lease_expires_at, :utc_datetime_usec)
    timestamps()
  end

  @type t :: %__MODULE__{}
end
