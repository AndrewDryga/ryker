defmodule Ryker.State.KnowledgeRevision do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "conversation_knowledge_revisions" do
    field(:knowledge_id, :binary_id, primary_key: true)
    field(:version, :integer, primary_key: true)
    field(:source_generation, :integer)
    field(:source_dependencies, Ryker.CanonicalJSON.Type)
    field(:state, Ryker.CanonicalJSON.Type)
    field(:source_input_id, :binary_id)
    field(:source_result_ref, :string)
    field(:source_at, :utc_datetime_usec)
    field(:inserted_at, :utc_datetime_usec)
  end
end
