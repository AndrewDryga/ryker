defmodule Ryker.State.SourceExposure do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "episode_work_source_exposures" do
    field(:session_id, :binary_id, primary_key: true)
    field(:observation_id, :binary_id, primary_key: true)
    field(:source_input_id, :binary_id, primary_key: true)
    field(:receipt, Ryker.CanonicalJSON.Type)
  end
end
