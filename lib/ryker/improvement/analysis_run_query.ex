defmodule Ryker.Improvement.AnalysisRunQuery do
  @moduledoc "Each analysis of a flagged request, for every read of `improvement_analysis_runs`."
  import Ecto.Query
  alias Ryker.Improvement.AnalysisRun

  def all, do: from(runs in AnalysisRun, as: :improvement_analysis_runs)

  @doc "The runs of `candidate_ids` that still keep their bodies."
  def kept_for_candidates(candidate_ids) do
    where(
      all(),
      [improvement_analysis_runs: r],
      r.candidate_id in ^candidate_ids and is_nil(r.pruned_at)
    )
  end
end
