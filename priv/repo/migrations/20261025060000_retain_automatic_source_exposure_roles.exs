defmodule Ryker.Repo.Migrations.RetainAutomaticSourceExposureRoles do
  use Ecto.Migration

  def up do
    alter table(:episode_work_source_exposures) do
      # Older memory custody cannot prove the read was an explicit search.
      add(:automatic_context, :boolean, null: false, default: true)
    end

    flush()

    # Known original inputs already prove they were never recalled as memory.
    # Keep that evidence without rewriting receipts or the rest of the ledger.
    execute("""
    DO $$
    DECLARE changed_rows integer;
    BEGIN
      LOOP
        WITH batch AS (
          SELECT ctid FROM episode_work_source_exposures
          WHERE input_only AND automatic_context LIMIT 5000
        )
        UPDATE episode_work_source_exposures AS exposure
        SET automatic_context = false FROM batch WHERE exposure.ctid = batch.ctid;
        GET DIAGNOSTICS changed_rows = ROW_COUNT;
        EXIT WHEN changed_rows = 0;
      END LOOP;
    END $$;
    """)
  end

  def down do
    alter table(:episode_work_source_exposures) do
      remove(:automatic_context)
    end
  end
end
