defmodule Ryker.CoopFleet.EnrollmentToken do
  @moduledoc false
  use Ryker, :schema

  schema "coop_worker_enrollment_tokens" do
    field(:worker_id, :string)
    field(:workspace_ref, :string)
    field(:operator_ref, :string)
    field(:token_sha256, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)
    field(:certificate_sha256, :string)

    timestamps(updated_at: false)
  end
end
