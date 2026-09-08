defmodule Responder.State.KnowledgeSource do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "conversation_knowledge_sources" do
    field(:knowledge_id, :binary_id, primary_key: true)
    field(:observation_id, :binary_id)
    field(:generation, :integer, primary_key: true)
    field(:receipt_fingerprint, :string, primary_key: true)
    field(:receipt, Responder.CanonicalJSON.Type)
    field(:direct_support_version, :integer)
    field(:source_revision, :integer)
    field(:source_fingerprint, :string)
    field(:source_note, Responder.CanonicalJSON.Type)
    field(:retained_at, :utc_datetime_usec)
    field(:introduced_version, :integer)
  end
end
