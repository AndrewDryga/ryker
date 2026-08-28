defmodule Responder.Work.Session do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "episode_work_sessions" do
    belongs_to(:episode, Responder.Episodes.Episode)
    field(:policy, :string)
    field(:policy_digest, :string)
    field(:external_ref, :string)
    field(:generation, :integer, default: 1)
    field(:create_generation, :integer, default: 1)
    field(:coop_session_id, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          episode_id: Ecto.UUID.t() | nil,
          policy: String.t() | nil,
          policy_digest: String.t() | nil,
          external_ref: String.t() | nil,
          generation: pos_integer(),
          create_generation: pos_integer(),
          coop_session_id: String.t() | nil
        }
end
