defmodule Ryker.Episodes.Origin do
  @moduledoc """
  The exact place one admitted input came from.

  Membership is per message: an episode has one progress home (its
  destination) and any number of origins. A direct answer to an input returns
  to that input's reply target, never to a place the model chose.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "episode_input_origins" do
    belongs_to(:episode, Ryker.Episodes.Episode)
    field(:input_ref, :string)
    field(:sequence, :integer)
    field(:native_input_id, :string)
    field(:revision, :integer)
    field(:source_kind, :string)
    field(:source_ref, :string)
    field(:source_item_ref, :string)
    field(:actor_ref, :string)
    field(:transport, :string)
    field(:conversation_ref, :string)
    field(:thread_ref, :string)
    field(:origin_kind, Ecto.Enum, values: [:channel_root, :thread_reply, :conversation])
    field(:root_ref, :string)
    field(:occurred_at, :utc_datetime_usec)
    field(:effective, :boolean, default: true)
    field(:correction_ref, :string)
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
