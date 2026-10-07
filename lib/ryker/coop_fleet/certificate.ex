defmodule Ryker.CoopFleet.Certificate do
  @moduledoc false
  use Ryker, :schema

  @primary_key {:sha256, :string, autogenerate: false}

  schema "coop_worker_certificates" do
    field(:worker_id, :string)
    field(:enrollment_token_id, Ecto.UUID)
    field(:serial_number, :string)
    field(:source, Ecto.Enum, values: [:enrollment, :renewal])
    field(:issued_by, :string)
    field(:not_before, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    field(:revoked_by, :string)

    timestamps(updated_at: false)
  end
end
