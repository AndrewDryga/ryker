defmodule Ryker.Repo.Migrations.RetireTheCutoverLedger do
  use Ecto.Migration

  # The cutover ledger recorded the one-time import of the Go-era SQLite state
  # into PostgreSQL: one row per reviewed run and one per copied memory,
  # behavior, schedule, episode or wait, each linked from the row it produced
  # through a `cutover_item_id`. The importer and its rollback were retired
  # with the Go gates, the production ledger holds no rows (0 runs, 0 items on
  # 2026-09-13), and nothing writes to it. This removes the two tables and the
  # five provenance links, and restores the NOT NULL provenance the ledger had
  # relaxed: every behavior, schedule and record is once again born from a
  # confirmed offer inside an episode turn. A memory entry keeps a nullable
  # offer because answer-confirmed global facts have none.
  #
  # The step refuses to run over a populated ledger rather than drop history
  # silently; the foreign keys already make a populated link impossible without
  # a ledger row, so an empty ledger proves every link column is NULL.
  def up do
    refuse_populated_ledger()

    drop(constraint(:operational_memory_entries, :operational_memory_provenance_valid))

    alter table(:operational_memory_entries) do
      remove(:cutover_item_id)
    end

    create(
      constraint(:operational_memory_entries, :operational_memory_provenance_valid,
        check: """
        (offer_record_id IS NOT NULL AND answer_provenance IS NULL) OR
        (offer_record_id IS NULL AND answer_provenance IS NOT NULL AND
         octet_length(answer_provenance) BETWEEN 2 AND 8192 AND scope_kind = 'global')
        """
      )
    )

    drop(constraint(:operator_behaviors, :operator_behavior_provenance_valid))

    alter table(:operator_behaviors) do
      remove(:cutover_item_id)
      modify(:offer_record_id, :uuid, null: false, from: {:uuid, null: true})
    end

    drop(constraint(:episode_schedules, :episode_schedule_provenance_valid))

    alter table(:episode_schedules) do
      remove(:cutover_item_id)
      modify(:offer_record_id, :uuid, null: false, from: {:uuid, null: true})
      modify(:source_episode_id, :uuid, null: false, from: {:uuid, null: true})
    end

    alter table(:episode_kernel_episodes) do
      remove(:cutover_item_id)
    end

    drop(constraint(:episode_state_records, :episode_state_record_provenance_valid))

    alter table(:episode_state_records) do
      remove(:cutover_item_id)
      modify(:turn_id, :uuid, null: false, from: {:uuid, null: true})
    end

    drop(table(:ryker_cutover_items))
    drop(table(:ryker_cutover_runs))
  end

  # Recreates the empty ledger exactly as the rename migration left it, so the
  # rename's own rollback still finds every object it renames.
  def down do
    create table(:ryker_cutover_runs, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:version, :integer, null: false)
      add(:status, :text, null: false)
      add(:manifest_sha256, :text, null: false)
      add(:review_sha256, :text, null: false)
      add(:source_kind, :text, null: false)
      add(:source_schema_sha256, :text, null: false)
      add(:source_schema_version, :integer, null: false)
      add(:source_sha256, :text, null: false)
      add(:workspace_ref, :text, null: false)
      add(:cutover_at, :utc_datetime_usec, null: false)
      add(:reviewed_at, :utc_datetime_usec, null: false)
      add(:operator_ref, :text, null: false)
      add(:summary, :text, null: false)
      add(:item_count, :integer, null: false)
      add(:applied_at, :utc_datetime_usec)
      add(:rolled_back_at, :utc_datetime_usec)
      add(:rolled_back_by, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:ryker_cutover_runs, [:manifest_sha256]))

    create(
      constraint(:ryker_cutover_runs, :ryker_cutover_run_valid,
        check: """
        version = 1 AND
        status IN ('prepared', 'applying', 'applied', 'rolled_back', 'failed') AND
        manifest_sha256 ~ '^[0-9a-f]{64}$' AND
        review_sha256 ~ '^[0-9a-f]{64}$' AND
        source_kind = 'responder_sqlite' AND
        source_schema_version = 90 AND
        source_schema_sha256 = 'e9aaa44b42dac7b2afe4e5740bcf6e4d24b9f93c2c2182781374e12e6643c535' AND
        source_sha256 ~ '^[0-9a-f]{64}$' AND
        char_length(workspace_ref) BETWEEN 1 AND 1024 AND
        char_length(operator_ref) BETWEEN 1 AND 1024 AND
        octet_length(summary) BETWEEN 2 AND 65536 AND
        jsonb_typeof(summary::jsonb) = 'object' AND
        item_count >= 0 AND
        ((status IN ('prepared', 'applying', 'failed') AND applied_at IS NULL AND rolled_back_at IS NULL AND rolled_back_by IS NULL) OR
         (status = 'applied' AND applied_at IS NOT NULL AND rolled_back_at IS NULL AND rolled_back_by IS NULL) OR
         (status = 'rolled_back' AND applied_at IS NOT NULL AND rolled_back_at IS NOT NULL AND char_length(rolled_back_by) BETWEEN 1 AND 1024))
        """
      )
    )

    create table(:ryker_cutover_items, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:run_id, references(:ryker_cutover_runs, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:ref, :text, null: false)
      add(:kind, :text, null: false)
      add(:source_table, :text, null: false)
      add(:source_ref, :text, null: false)
      add(:source_sha256, :text, null: false)
      add(:decision, :text, null: false)
      add(:status, :text, null: false)
      add(:data, :text, null: false)
      add(:target_refs, :text)
      add(:target_fingerprint, :text)
      add(:error_code, :text)
      add(:error_detail, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:ryker_cutover_items, [:run_id, :ref]))
    create(unique_index(:ryker_cutover_items, [:run_id, :source_table, :source_ref]))
    create(index(:ryker_cutover_items, [:run_id, :status, :kind, :id]))

    create(
      constraint(:ryker_cutover_items, :ryker_cutover_item_valid,
        check: """
        char_length(ref) BETWEEN 1 AND 1024 AND
        kind IN ('memory', 'behavior', 'schedule', 'episode', 'wait') AND
        source_table IN ('memory_entries', 'scheduled_tasks', 'standing_rules', 'work_episodes', 'episode_wakeups') AND
        char_length(source_ref) BETWEEN 1 AND 1024 AND
        source_sha256 ~ '^[0-9a-f]{64}$' AND
        decision IN ('import', 'skip') AND
        status IN ('pending', 'applied', 'skipped', 'rolled_back', 'failed') AND
        octet_length(data) BETWEEN 2 AND 262144 AND
        jsonb_typeof(data::jsonb) = 'object' AND
        ((status = 'pending' AND decision = 'import' AND target_refs IS NULL AND target_fingerprint IS NULL AND error_code IS NULL AND error_detail IS NULL) OR
         (status = 'skipped' AND decision = 'skip' AND target_refs IS NULL AND target_fingerprint IS NULL AND error_code IS NULL AND error_detail IS NULL) OR
         (status = 'applied' AND decision = 'import' AND target_refs IS NOT NULL AND jsonb_typeof(target_refs::jsonb) = 'array' AND target_fingerprint ~ '^[0-9a-f]{64}$' AND error_code IS NULL AND error_detail IS NULL) OR
         (status = 'rolled_back' AND decision = 'import' AND target_refs IS NOT NULL AND jsonb_typeof(target_refs::jsonb) = 'array' AND target_fingerprint ~ '^[0-9a-f]{64}$' AND error_code IS NULL AND error_detail IS NULL) OR
         (status = 'failed' AND decision = 'import' AND target_refs IS NULL AND target_fingerprint IS NULL AND char_length(error_code) BETWEEN 1 AND 128 AND octet_length(error_detail) BETWEEN 1 AND 4096))
        """
      )
    )

    for table <- ["ryker_cutover_runs", "ryker_cutover_items"] do
      execute("""
      CREATE TRIGGER ryker_control_plane_changed
      AFTER INSERT OR UPDATE OR DELETE ON #{qualified(table)}
      FOR EACH STATEMENT EXECUTE FUNCTION #{qualified("ryker_control_plane_notify")}()
      """)
    end

    alter table(:episode_state_records) do
      modify(:turn_id, :uuid, null: true, from: {:uuid, null: false})
      add(:cutover_item_id, references(:ryker_cutover_items, type: :uuid, on_delete: :restrict))
    end

    create(unique_index(:episode_state_records, [:cutover_item_id]))

    create(
      constraint(:episode_state_records, :episode_state_record_provenance_valid,
        check:
          "(turn_id IS NOT NULL AND cutover_item_id IS NULL) OR (turn_id IS NULL AND cutover_item_id IS NOT NULL)"
      )
    )

    alter table(:episode_kernel_episodes) do
      add(:cutover_item_id, references(:ryker_cutover_items, type: :uuid, on_delete: :restrict))
    end

    create(unique_index(:episode_kernel_episodes, [:cutover_item_id]))

    alter table(:episode_schedules) do
      modify(:source_episode_id, :uuid, null: true, from: {:uuid, null: false})
      modify(:offer_record_id, :uuid, null: true, from: {:uuid, null: false})
      add(:cutover_item_id, references(:ryker_cutover_items, type: :uuid, on_delete: :restrict))
    end

    create(index(:episode_schedules, [:cutover_item_id]))

    create(
      constraint(:episode_schedules, :episode_schedule_provenance_valid,
        check: """
        (offer_record_id IS NOT NULL AND source_episode_id IS NOT NULL AND cutover_item_id IS NULL) OR
        (offer_record_id IS NULL AND source_episode_id IS NULL AND cutover_item_id IS NOT NULL)
        """
      )
    )

    alter table(:operator_behaviors) do
      modify(:offer_record_id, :uuid, null: true, from: {:uuid, null: false})
      add(:cutover_item_id, references(:ryker_cutover_items, type: :uuid, on_delete: :restrict))
    end

    create(unique_index(:operator_behaviors, [:cutover_item_id]))

    create(
      constraint(:operator_behaviors, :operator_behavior_provenance_valid,
        check:
          "(offer_record_id IS NOT NULL AND cutover_item_id IS NULL) OR (offer_record_id IS NULL AND cutover_item_id IS NOT NULL)"
      )
    )

    drop(constraint(:operational_memory_entries, :operational_memory_provenance_valid))

    alter table(:operational_memory_entries) do
      add(:cutover_item_id, references(:ryker_cutover_items, type: :uuid, on_delete: :restrict))
    end

    create(unique_index(:operational_memory_entries, [:cutover_item_id]))

    create(
      constraint(:operational_memory_entries, :operational_memory_provenance_valid,
        check: """
        (offer_record_id IS NOT NULL AND cutover_item_id IS NULL AND answer_provenance IS NULL) OR
        (offer_record_id IS NULL AND cutover_item_id IS NOT NULL AND answer_provenance IS NULL) OR
        (offer_record_id IS NULL AND cutover_item_id IS NULL AND answer_provenance IS NOT NULL AND
         octet_length(answer_provenance) BETWEEN 2 AND 8192 AND scope_kind = 'global')
        """
      )
    )
  end

  defp refuse_populated_ledger do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("ryker_cutover_runs")} LIMIT 1)
         OR EXISTS (SELECT 1 FROM #{qualified("ryker_cutover_items")} LIMIT 1) THEN
        RAISE EXCEPTION 'the cutover ledger has data; retiring it would drop import history';
      END IF;
    END
    $$
    """)
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
