defmodule Responder.State.ConversationSummaryDraft do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "conversation_summary_drafts" do
    belongs_to(:episode, Responder.Episodes.Episode)
    belongs_to(:turn, Responder.Work.Turn)
    field(:revision, :integer, default: 1)
    field(:state, Responder.CanonicalJSON.Type)
    field(:state_fingerprint, :string)
    field(:candidate_sha256, :string)
    field(:candidate_attempt, :integer)
    timestamps(type: :utc_datetime_usec)
  end
end
