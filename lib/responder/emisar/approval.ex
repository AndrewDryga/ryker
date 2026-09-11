defmodule Responder.Emisar.Approval do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "episode_emisar_approvals" do
    belongs_to(:record, Responder.State.Record)
    belongs_to(:episode, Responder.Episodes.Episode)

    field(:request_id, :string)
    field(:run_id, :string)
    field(:operation_id, :string)
    field(:action_id, :string)
    field(:pack_ref, :string)
    field(:runner_ref, :string)
    field(:approval_url, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:status, Ecto.Enum, values: [:monitoring, :resumed, :blocked])
    field(:remote_status, :string)
    field(:run_url, :string)
    field(:remote_error, :string)
    field(:review_digest, :string)
    field(:last_observed_at, :utc_datetime_usec)
    field(:terminal_at, :utc_datetime_usec)
    field(:resumed_at, :utc_datetime_usec)
    field(:failure_count, :integer, default: 0)
    field(:last_error, :string)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:lease_ref, :string)
    field(:lease_owner, :string)
    field(:lease_expires_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
