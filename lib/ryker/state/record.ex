defmodule Ryker.State.Record do
  @moduledoc """
  One inert, typed record created by an active episode turn.

  A record can be cited by the model's small final result, but it grants no
  external authority by itself. Platform cards and confirmations remain
  host-owned transitions over this exact durable payload.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "episode_state_records" do
    belongs_to(:episode, Ryker.Episodes.Episode)
    belongs_to(:turn, Ryker.Work.Turn)
    field(:ref, :string)
    field(:sequence, :integer, read_after_writes: true)
    field(:operation_id, :string)
    field(:kind, :string)
    field(:status, Ecto.Enum, values: [:open, :confirmed, :answered, :dismissed, :superseded])
    field(:wait_error, :string)
    field(:subject_ref, :string)
    field(:payload, Ryker.CanonicalJSON.Type)
    field(:payload_fingerprint, :string)
    field(:continuation, Ryker.CanonicalJSON.Type)
    field(:confirmed_episode_id, :binary_id)
    field(:confirmation_ref, :string)
    field(:confirmed_by_actor_ref, :string)
    field(:confirmed_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          episode_id: Ecto.UUID.t() | nil,
          turn_id: Ecto.UUID.t() | nil,
          ref: String.t() | nil,
          sequence: pos_integer() | nil,
          operation_id: String.t() | nil,
          kind: String.t() | nil,
          status: :open | :confirmed | :answered | :dismissed | :superseded | nil,
          wait_error: String.t() | nil,
          subject_ref: String.t() | nil,
          payload: map() | nil,
          payload_fingerprint: String.t() | nil,
          continuation: map() | nil,
          confirmed_episode_id: Ecto.UUID.t() | nil,
          confirmation_ref: String.t() | nil,
          confirmed_by_actor_ref: String.t() | nil,
          confirmed_at: DateTime.t() | nil
        }
end
