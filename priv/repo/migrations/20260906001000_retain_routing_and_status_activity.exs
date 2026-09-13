defmodule Ryker.Repo.Migrations.RetainRoutingAndStatusActivity do
  use Ecto.Migration

  def up do
    alter table(:episode_work_sessions) do
      add(
        :admission_input_id,
        references(:ingress_inbox_entries, type: :uuid, on_delete: :nilify_all)
      )
    end

    execute(
      "UPDATE #{qualified("episode_work_sessions")} s SET admission_input_id = i.id FROM #{qualified("ingress_inbox_entries")} i WHERE s.execution_kind = 'admission' AND s.external_ref = 'responder-admission:' || i.id::text || ':g' || s.generation::text"
    )

    create(unique_index(:episode_work_sessions, [:id, :admission_input_id]))

    alter table(:episode_work_activity) do
      modify(:episode_id, :uuid, null: true)
      add(:remote_payload_fingerprint, :text)
      add(:operational_pruned_at, :utc_datetime_usec)

      add(
        :admission_input_id,
        references(:ingress_inbox_entries, type: :uuid, on_delete: :delete_all)
      )
    end

    execute(
      "ALTER TABLE #{qualified("episode_work_activity")} ADD CONSTRAINT activity_admission_session_fkey FOREIGN KEY (session_id, admission_input_id) REFERENCES #{qualified("episode_work_sessions")} (id, admission_input_id)"
    )

    create(
      constraint(:episode_work_activity, :activity_owner_valid,
        check: "(episode_id IS NOT NULL) <> (admission_input_id IS NOT NULL)"
      )
    )

    create(index(:episode_work_activity, [:admission_input_id, :occurred_at, :sequence]))

    alter table(:slack_thread_statuses) do
      add(:origin_kind, :text)
      add(:origin_id, :uuid)
    end

    create table(:slack_thread_status_receipts, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:workspace_ref, :text, null: false)
      add(:channel_ref, :text, null: false)
      add(:thread_ref, :text, null: false)
      add(:generation, :bigint, null: false)
      add(:lease_ref, :uuid, null: false)
      add(:origin_kind, :text)
      add(:origin_id, :uuid)
      add(:phase, :text, null: false)
      add(:text, :text, null: false)
      add(:error, :text)
      add(:acknowledged_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:slack_thread_status_receipts, [:lease_ref]))
    create(index(:slack_thread_status_receipts, [:origin_kind, :origin_id, :inserted_at]))

    create(
      index(:slack_thread_status_receipts, [
        :workspace_ref,
        :channel_ref,
        :thread_ref,
        :inserted_at
      ])
    )
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("episode_work_activity")} WHERE admission_input_id IS NOT NULL OR remote_payload_fingerprint IS NOT NULL OR operational_pruned_at IS NOT NULL LIMIT 1)
        OR EXISTS (SELECT 1 FROM #{qualified("slack_thread_status_receipts")} LIMIT 1)
        OR EXISTS (SELECT 1 FROM #{qualified("slack_thread_statuses")} WHERE origin_id IS NOT NULL LIMIT 1)
      THEN RAISE EXCEPTION 'export retained routing and Slack status activity before rollback'; END IF;
    END $$
    """)

    drop(table(:slack_thread_status_receipts))

    alter table(:slack_thread_statuses) do
      remove(:origin_kind)
      remove(:origin_id)
    end

    drop(constraint(:episode_work_activity, :activity_owner_valid))

    execute(
      "ALTER TABLE #{qualified("episode_work_activity")} DROP CONSTRAINT activity_admission_session_fkey"
    )

    alter table(:episode_work_activity) do
      remove(:admission_input_id)
      remove(:remote_payload_fingerprint)
      remove(:operational_pruned_at)
      modify(:episode_id, :uuid, null: false)
    end

    alter table(:episode_work_sessions) do
      remove(:admission_input_id)
    end
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
