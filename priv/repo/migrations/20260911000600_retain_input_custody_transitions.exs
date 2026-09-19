defmodule Ryker.Repo.Migrations.RetainInputCustodyTransitions do
  use Ecto.Migration

  def up do
    create table(:input_custody_transitions, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :input_id,
        references(:ingress_inbox_entries, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:sequence, :bigint, null: false)
      add(:kind, :text, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:generation, :bigint, null: false)
      add(:attempt, :bigint, null: false)

      add(
        :predecessor_input_id,
        references(:ingress_inbox_entries, type: :uuid, on_delete: :nilify_all)
      )

      add(
        :superseding_input_id,
        references(:ingress_inbox_entries, type: :uuid, on_delete: :nilify_all)
      )

      add(:owner_ref, :text)
      add(:eligible_at, :utc_datetime_usec)
      add(:error_code, :text)
      add(:detail, :text)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:input_custody_transitions, [:input_id, :sequence]))
    create(index(:input_custody_transitions, [:input_id, :occurred_at, :sequence]))

    create(
      constraint(:input_custody_transitions, :input_custody_transition_valid,
        check: """
        sequence > 0 AND generation > 0 AND attempt >= 0 AND
        kind IN ('saved', 'waiting_predecessor', 'claimed', 'reclaimed',
                 'retry_scheduled', 'blocked', 'rearmed', 'superseded') AND
        (owner_ref IS NULL OR char_length(owner_ref) BETWEEN 1 AND 1024) AND
        (error_code IS NULL OR char_length(error_code) BETWEEN 1 AND 128) AND
        (detail IS NULL OR char_length(detail) BETWEEN 1 AND 4096) AND
        (predecessor_input_id IS NULL OR kind = 'waiting_predecessor') AND
        (kind = 'superseded' OR superseding_input_id IS NULL)
        """
      )
    )

    execute("""
    DO $$ DECLARE notify_name text; BEGIN
      IF EXISTS (
        SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = '#{schema_literal()}' AND p.proname = 'ryker_control_plane_notify'
      ) THEN
        notify_name := 'ryker';
      ELSE
        notify_name := 'responder';
      END IF;

      EXECUTE format(
        'CREATE TRIGGER %I AFTER INSERT OR UPDATE OR DELETE ON %I.input_custody_transitions FOR EACH STATEMENT EXECUTE FUNCTION %I.%I()',
        notify_name || '_control_plane_changed', '#{schema_literal()}',
        '#{schema_literal()}', notify_name || '_control_plane_notify'
      );
    END $$;
    """)
  end

  def down do
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("input_custody_transitions")} LIMIT 1) THEN
        RAISE EXCEPTION 'input custody transition history must be exported before rollback';
      END IF;
    END $$;
    """)

    drop(table(:input_custody_transitions))
  end

  defp schema_literal, do: String.replace(prefix() || "public", "'", "''")

  defp qualified(name),
    do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}".#{name})
end
