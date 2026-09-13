defmodule Ryker.Repo.Migrations.AttestWorkSourceExposureCounts do
  use Ecto.Migration

  def change do
    alter table(:episode_work_sessions) do
      # Null means unproven, including sessions that predate disclosure custody.
      # Never backfill old absence as a tracked, source-free transcript.
      add(:source_exposure_count, :bigint)
      add(:knowledge_exposure_count, :bigint)
    end

    create(
      constraint(:episode_work_sessions, :work_source_exposure_counts_valid,
        check: """
        (source_exposure_count IS NULL AND knowledge_exposure_count IS NULL)
        OR (source_exposure_count >= 0 AND knowledge_exposure_count >= 0
          AND source_exposure_count IS NOT NULL AND knowledge_exposure_count IS NOT NULL)
        """
      )
    )
  end
end
