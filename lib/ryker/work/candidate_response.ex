defmodule Ryker.Work.CandidateResponse do
  @moduledoc "An exact candidate attempt retained independently of the turn's execution cursor."
  use Ecto.Schema

  @primary_key false
  schema "work_candidate_responses" do
    field(:turn_id, :binary_id, primary_key: true)
    field(:candidate_attempt, :integer, primary_key: true)
    field(:body, :string)
    field(:sha256, :string)
    field(:byte_size, :integer)
    field(:recorded_at, :utc_datetime_usec)
    field(:operational_pruned_at, :utc_datetime_usec)
  end
end
