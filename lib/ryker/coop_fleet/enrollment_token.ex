defmodule Ryker.CoopFleet.EnrollmentToken do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "coop_worker_enrollment_tokens" do
    field(:worker_id, :string)
    field(:workspace_ref, :string)
    field(:operator_ref, :string)
    field(:token_sha256, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)
    field(:certificate_sha256, :string)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
