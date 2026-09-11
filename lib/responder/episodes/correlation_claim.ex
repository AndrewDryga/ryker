defmodule Responder.Episodes.CorrelationClaim do
  @moduledoc """
  One trusted occurrence identity owned by one active episode.

  A claim is scoped by security domain and by the authenticated source that
  reported it; a service, alert rule, URL, or old incident mentioned for
  comparison never becomes a claim. The unique active owner is the fence that
  keeps two channels from creating duplicate work for one occurrence.
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "episode_correlation_claims" do
    belongs_to(:episode, Responder.Episodes.Episode)
    field(:input_ref, :string)
    field(:scope_ref, :string)
    field(:namespace, :string)
    field(:occurrence_ref, :string)
    field(:lifecycle_state, Ecto.Enum, values: [:active, :terminal], default: :active)
    field(:status, Ecto.Enum, values: [:active, :retired], default: :active)
    field(:established_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
