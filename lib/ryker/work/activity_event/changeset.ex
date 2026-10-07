defmodule Ryker.Work.ActivityEvent.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.Work.ActivityEvent

  @fields [
    :coop_turn_id,
    :episode_id,
    :admission_input_id,
    :kind,
    :occurred_at,
    :payload,
    :payload_fingerprint,
    :remote_payload_fingerprint,
    :operational_pruned_at,
    :remote_event_id,
    :remote_session_id,
    :sequence,
    :session_id,
    :version
  ]

  @required [
    :kind,
    :occurred_at,
    :payload,
    :payload_fingerprint,
    :remote_event_id,
    :remote_session_id,
    :sequence,
    :session_id,
    :version
  ]

  @spec insert(map()) :: Ecto.Changeset.t()
  def insert(attributes) do
    %ActivityEvent{}
    |> cast(attributes, @fields)
    |> validate_required(@required)
    |> check_constraint(:episode_id, name: :activity_owner_valid)
  end
end
