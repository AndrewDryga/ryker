defmodule Ryker.Repo.Migrations.NotifyControlPlaneChanges do
  use Ecto.Migration

  def up do
    execute("""
    CREATE FUNCTION #{function_name()}() RETURNS trigger AS $$
    BEGIN
      PERFORM pg_notify('responder_control_plane', TG_TABLE_NAME);
      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """)

    execute("""
    DO $$ DECLARE relation record; BEGIN
      FOR relation IN
        SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = '#{schema_literal()}' AND c.relkind IN ('r', 'p')
          AND c.relname NOT IN ('schema_migrations', 'responder_runtime_progress')
      LOOP
        EXECUTE format('CREATE TRIGGER responder_control_plane_changed AFTER INSERT OR UPDATE OR DELETE ON %I.%I FOR EACH STATEMENT EXECUTE FUNCTION %I.responder_control_plane_notify()',
                       '#{schema_literal()}', relation.relname, '#{schema_literal()}');
      END LOOP;
    END $$;
    """)
  end

  def down do
    execute("""
    DO $$ DECLARE relation record; BEGIN
      FOR relation IN
        SELECT c.relname FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
          JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = '#{schema_literal()}' AND t.tgname = 'responder_control_plane_changed'
      LOOP
        EXECUTE format('DROP TRIGGER responder_control_plane_changed ON %I.%I',
                       '#{schema_literal()}', relation.relname);
      END LOOP;
    END $$;
    """)

    execute("DROP FUNCTION #{function_name()}()")
  end

  defp schema_literal, do: String.replace(prefix() || "public", "'", "''")

  defp function_name,
    do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}".responder_control_plane_notify)
end
