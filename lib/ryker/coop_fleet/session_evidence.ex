defmodule Ryker.CoopFleet.SessionEvidence do
  @moduledoc """
  One worker-exported snapshot of a Coop session, kept as evidence of what
  the session was doing (`Ryker.CoopFleet.SessionEvidences`).
  """
  use Ryker, :schema

  schema "coop_session_evidence" do
    belongs_to(:session, Ryker.Work.Session)
    belongs_to(:episode, Ryker.Episodes.Episode)
    field(:coop_session_id, :string)
    field(:worker_id, :string)
    field(:placement_generation, :integer)
    field(:evidence_version, :integer)
    field(:content_fingerprint, :string)
    field(:document, :string)
    field(:session_revision, :integer)
    field(:session_state, :string)
    field(:network_mode, :string)
    field(:task_status, :string)
    field(:first_captured_at, :utc_datetime_usec)
    field(:last_captured_at, :utc_datetime_usec)
    field(:capture_count, :integer)
  end

  @type t :: %__MODULE__{}
end
