defmodule Ryker.Work.ActivityEvent do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "episode_work_activity" do
    belongs_to(:episode, Ryker.Episodes.Episode)
    belongs_to(:admission_input, Ryker.Ingress.Inbox.Entry)
    belongs_to(:session, Ryker.Work.Session)
    field(:remote_event_id, :string)
    field(:remote_session_id, :string)
    field(:coop_turn_id, :string)
    field(:sequence, :integer)
    field(:kind, :string)
    field(:version, :integer)
    field(:occurred_at, :utc_datetime_usec)
    field(:payload, Ryker.CanonicalJSON.Type)
    field(:payload_fingerprint, :string)
    field(:remote_payload_fingerprint, :string)
    field(:operational_pruned_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          episode_id: Ecto.UUID.t() | nil,
          session_id: Ecto.UUID.t() | nil,
          remote_event_id: String.t() | nil,
          remote_session_id: String.t() | nil,
          coop_turn_id: String.t() | nil,
          sequence: pos_integer() | nil,
          kind: String.t() | nil,
          version: pos_integer() | nil,
          occurred_at: DateTime.t() | nil,
          payload: map() | nil,
          payload_fingerprint: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }
end
