defmodule Ryker.Learning.SourceExposure do
  @moduledoc false
  use Ryker, :schema

  @primary_key false
  schema "episode_work_source_exposures" do
    field(:session_id, :binary_id, primary_key: true)
    field(:observation_id, :binary_id, primary_key: true)
    field(:source_input_id, :binary_id, primary_key: true)
    field(:receipt, Ryker.CanonicalJSON.Type)
    field(:input_only, :boolean, default: false)
    field(:automatic_context, :boolean, default: true)
  end
end
