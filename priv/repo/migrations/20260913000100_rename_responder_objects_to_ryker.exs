defmodule Ryker.Repo.Migrations.RenameResponderObjectsToRyker do
  use Ecto.Migration

  @moduledoc """
  The product was renamed from Responder to Ryker on 2026-09-13. This renames
  the database objects that carried the old name: four tables with their
  indexes and constraints, the `github_binding_settings.responder_actor_id`
  column, the learning-roots function, and the control-plane NOTIFY function,
  trigger and channel, which are dropped and recreated on every table because
  the listener switches channel in the same release. The publication defaults
  move to the new name without touching the live row, which is the operator's
  setting.

  No row changes: idempotency keys, external refs, audit action ids, cutover
  source kinds and sealed checkpoints keep the values they were written with.
  """

  @tables ~w(runtime_progress operator_actions cutover_runs cutover_items)

  def up do
    drop_notify("responder")
    Enum.each(@tables, &rename_table(&1, "responder", "ryker"))
    rename_column("responder", "ryker")

    execute(
      "ALTER FUNCTION #{qualified("responder_learning_roots")}(text) RENAME TO ryker_learning_roots"
    )

    create_notify("ryker")

    execute("""
    ALTER TABLE #{qualified("publication_settings")}
      ALTER COLUMN branch_prefix SET DEFAULT 'ryker',
      ALTER COLUMN commit_name SET DEFAULT 'Ryker',
      ALTER COLUMN commit_email SET DEFAULT 'ryker@localhost'
    """)
  end

  def down do
    execute("""
    ALTER TABLE #{qualified("publication_settings")}
      ALTER COLUMN branch_prefix SET DEFAULT 'responder',
      ALTER COLUMN commit_name SET DEFAULT 'Responder',
      ALTER COLUMN commit_email SET DEFAULT 'responder@localhost'
    """)

    drop_notify("ryker")

    execute(
      "ALTER FUNCTION #{qualified("ryker_learning_roots")}(text) RENAME TO responder_learning_roots"
    )

    rename_column("ryker", "responder")
    Enum.each(@tables, &rename_table(&1, "ryker", "responder"))
    create_notify("responder")
  end

  # The table moves with every index and constraint that carries its prefix,
  # including the primary key, the foreign key, the CHECK constraints and the
  # NOT NULL constraints PostgreSQL 18 names after the table.
  defp rename_table(suffix, from, to) do
    execute("ALTER TABLE #{qualified("#{from}_#{suffix}")} RENAME TO #{to}_#{suffix}")

    execute("""
    DO $$ DECLARE object record; BEGIN
      FOR object IN
        SELECT c.conname AS name FROM pg_constraint c
        WHERE c.conrelid = '#{qualified("#{to}_#{suffix}")}'::regclass AND c.conname LIKE '#{from}\\_%'
      LOOP
        EXECUTE format('ALTER TABLE %s RENAME CONSTRAINT %I TO %I', '#{qualified("#{to}_#{suffix}")}',
                       object.name, '#{to}' || substr(object.name, #{String.length(from) + 1}));
      END LOOP;
      FOR object IN
        SELECT i.indexrelid::regclass::text AS qualified, ic.relname AS name FROM pg_index i
          JOIN pg_class ic ON ic.oid = i.indexrelid
        WHERE i.indrelid = '#{qualified("#{to}_#{suffix}")}'::regclass AND ic.relname LIKE '#{from}\\_%'
          AND NOT EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conindid = i.indexrelid)
      LOOP
        EXECUTE format('ALTER INDEX %s RENAME TO %I', object.qualified,
                       '#{to}' || substr(object.name, #{String.length(from) + 1}));
      END LOOP;
    END $$;
    """)
  end

  defp rename_column(from, to) do
    table = qualified("github_binding_settings")
    execute("ALTER TABLE #{table} RENAME COLUMN #{from}_actor_id TO #{to}_actor_id")

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM pg_constraint
                 WHERE conrelid = '#{table}'::regclass
                   AND conname = 'github_binding_settings_#{from}_actor_id_not_null') THEN
        ALTER TABLE #{table} RENAME CONSTRAINT github_binding_settings_#{from}_actor_id_not_null
          TO github_binding_settings_#{to}_actor_id_not_null;
      END IF;
    END $$;
    """)
  end

  defp drop_notify(name) do
    execute("""
    DO $$ DECLARE relation record; BEGIN
      FOR relation IN
        SELECT c.relname FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = '#{schema_literal()}' AND t.tgname = '#{name}_control_plane_changed'
      LOOP
        EXECUTE format('DROP TRIGGER #{name}_control_plane_changed ON %I.%I',
                       '#{schema_literal()}', relation.relname);
      END LOOP;
    END $$;
    """)

    execute("DROP FUNCTION IF EXISTS #{qualified("#{name}_control_plane_notify")}()")
  end

  # Every table notifies except the migration ledger and the heartbeat table,
  # which would otherwise fire on every poller cycle.
  defp create_notify(name) do
    execute("""
    CREATE FUNCTION #{qualified("#{name}_control_plane_notify")}() RETURNS trigger AS $$
    BEGIN
      PERFORM pg_notify('#{name}_control_plane', TG_TABLE_NAME);
      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    DO $$ DECLARE relation record; BEGIN
      FOR relation IN
        SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = '#{schema_literal()}' AND c.relkind IN ('r', 'p')
          AND c.relname NOT IN ('schema_migrations', '#{name}_runtime_progress')
      LOOP
        EXECUTE format('CREATE TRIGGER #{name}_control_plane_changed AFTER INSERT OR UPDATE OR DELETE ON %I.%I FOR EACH STATEMENT EXECUTE FUNCTION %I.#{name}_control_plane_notify()',
                       '#{schema_literal()}', relation.relname, '#{schema_literal()}');
      END LOOP;
    END $$;
    """)
  end

  defp schema_literal, do: String.replace(prefix() || "public", "'", "''")

  defp qualified(name),
    do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}".#{name})
end
