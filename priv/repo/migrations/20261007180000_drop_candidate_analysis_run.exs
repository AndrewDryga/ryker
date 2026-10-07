defmodule Ryker.Repo.Migrations.DropCandidateAnalysisRun do
  use Ecto.Migration

  # A candidate kept the id of the run whose diagnosis it took, and nothing
  # read it (2026-10-04 review): that run already names the candidate and is
  # the one marked `applied`. On 2026-10-07 every live value was the
  # candidate's newest applied run.

  def up do
    alter table(:improvement_candidates) do
      remove(:analysis_run_id)
    end
  end

  def down do
    alter table(:improvement_candidates) do
      add(:analysis_run_id, :uuid)
    end

    execute("""
    UPDATE improvement_candidates AS candidate
    SET analysis_run_id = (
      SELECT run.id FROM improvement_analysis_runs AS run
      WHERE run.candidate_id = candidate.id AND run.status = 'applied'
      ORDER BY run.generation DESC
      LIMIT 1
    )
    """)
  end
end
