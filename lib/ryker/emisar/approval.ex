defmodule Ryker.Emisar.Approval do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "episode_emisar_approvals" do
    belongs_to(:record, Ryker.State.Record)
    belongs_to(:episode, Ryker.Episodes.Episode)

    field(:connection_ref, :string)
    field(:request_id, :string)
    field(:run_id, :string)
    field(:operation_id, :string)
    field(:action_id, :string)
    field(:pack_ref, :string)
    field(:runner_ref, :string)
    field(:approval_url, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:status, Ecto.Enum, values: [:monitoring, :resumed, :blocked, :closed])
    field(:remote_status, :string)
    field(:run_url, :string)
    field(:remote_error, :string)
    field(:review_digest, :string)
    field(:last_observed_at, :utc_datetime_usec)
    field(:terminal_at, :utc_datetime_usec)
    field(:resumed_at, :utc_datetime_usec)
    # Set together with status :closed: the task no longer waits for it.
    field(:closed_at, :utc_datetime_usec)
    field(:closed_reason, :string)
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
