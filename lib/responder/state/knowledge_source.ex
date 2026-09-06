defmodule Responder.State.KnowledgeSource do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "conversation_knowledge_sources" do
    field(:knowledge_id, :binary_id, primary_key: true)
    field(:observation_id, :binary_id, primary_key: true)
    field(:generation, :integer, primary_key: true)
    field(:source_revision, :integer)
    field(:source_fingerprint, :string)
    field(:source_note, Responder.CanonicalJSON.Type)
    field(:retained_at, :utc_datetime_usec)
    field(:introduced_version, :integer)
  end
end
