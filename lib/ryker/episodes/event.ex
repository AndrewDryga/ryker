defmodule Ryker.Episodes.Event do
  @moduledoc """
  One immutable decision made by the episode kernel.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "episode_kernel_events" do
    field(:sequence, :integer)

    field(:kind, Ecto.Enum,
      values: [
        :input_admitted,
        :owner_transferred,
        :input_wait_started,
        :event_wait_started,
        :wait_resumed,
        :result_accepted,
        :delivery_confirmed,
        :episode_cancelled,
        :reaction_recorded
      ]
    )

    field(:dedupe_key, :string)
    field(:fingerprint, :string)
    field(:payload, Ryker.CanonicalJSON.Type)
    field(:occurred_at, :utc_datetime_usec)
    belongs_to(:episode, Ryker.Episodes.Episode)

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          sequence: pos_integer() | nil,
          kind: atom() | nil,
          dedupe_key: String.t() | nil,
          fingerprint: String.t() | nil,
          payload: map() | nil,
          occurred_at: DateTime.t() | nil,
          episode_id: Ecto.UUID.t() | nil
        }
end
