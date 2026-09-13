defmodule Ryker.Episodes.RoutingDigest do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  schema "episode_routing_digests" do
    belongs_to(:episode, Ryker.Episodes.Episode, primary_key: true)
    field(:objective, :string)
    field(:latest_development, :string)
    field(:search_text, :string)
    field(:anchor_keys, {:array, :string}, default: [])
    field(:conversation_refs, {:array, :string}, default: [])
    field(:input_count, :integer, default: 0)
    field(:covered_through_sequence, :integer)
    field(:covered_through_at, :utc_datetime_usec)
    field(:latest_revision, :integer)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
