defmodule Ryker.CoopFleet.Certificate do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:sha256, :string, autogenerate: false}

  schema "coop_worker_certificates" do
    field(:worker_id, :string)
    field(:enrollment_token_id, Ecto.UUID)
    field(:serial_number, :string)
    field(:source, Ecto.Enum, values: [:enrollment, :renewal, :manual])
    field(:issued_by, :string)
    field(:not_before, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    field(:revoked_by, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
