defmodule Responder.State.KnowledgeExposure do
  @moduledoc false
  use Ecto.Schema
  @primary_key false

  schema "episode_work_knowledge_exposures" do
    field(:session_id, :binary_id, primary_key: true)
    field(:knowledge_id, :binary_id, primary_key: true)
    field(:version, :integer, primary_key: true)
    field(:turn_id, :binary_id)
    field(:inserted_at, :utc_datetime_usec)
  end
end
