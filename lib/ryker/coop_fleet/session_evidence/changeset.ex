defmodule Ryker.CoopFleet.SessionEvidence.Changeset do
  @moduledoc "The one write of session evidence: a new snapshot of a session's state."
  use Ryker, :changeset
  alias Ryker.CoopFleet.SessionEvidence

  @fields ~w(id session_id episode_id coop_session_id worker_id placement_generation
    evidence_version content_fingerprint document session_revision session_state network_mode
    task_status first_captured_at last_captured_at capture_count)a

  @doc "A snapshot to insert; two of the same session state meet at the unique index."
  def insert(attributes) do
    %SessionEvidence{}
    |> cast(attributes, @fields)
    |> validate_required(@fields -- [:episode_id])
    |> unique_constraint([:session_id, :content_fingerprint])
    |> check_constraint(:document, name: :coop_session_evidence_valid)
  end
end
