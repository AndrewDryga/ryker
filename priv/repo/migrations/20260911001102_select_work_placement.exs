defmodule Responder.Repo.Migrations.SelectWorkPlacement do
  use Ecto.Migration

  # Which enrolled worker workspace runs Work is an operator selection, not a
  # deployment environment variable and not a code default: it names trusted
  # infrastructure that must survive restarts with the installation identity.
  def up do
    create table(:work_settings, primary_key: false) do
      add(
        :id,
        references(:installation_settings,
          column: :host_ref,
          type: :text,
          on_delete: :delete_all
        ),
        primary_key: true
      )

      add(:workspace_ref, :text)
    end

    create(
      constraint(:work_settings, :work_settings_valid,
        check: "workspace_ref IS NULL OR char_length(workspace_ref) BETWEEN 1 AND 256"
      )
    )

    drop(constraint(:settings_edits, :settings_edit_valid))
    create(edit_constraint(true))
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("work_settings")} WHERE workspace_ref IS NOT NULL LIMIT 1) THEN
        RAISE EXCEPTION 'work placement settings have data and cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    drop(table(:work_settings))
    drop(constraint(:settings_edits, :settings_edit_valid))
    create(edit_constraint(false))
  end

  defp edit_constraint(work?) do
    domains =
      ~w(installation retention slack github publication emisar report learning repositories policies webhooks pricing import) ++
        if(work?, do: ["work"], else: [])

    constraint(:settings_edits, :settings_edit_valid,
      check:
        "domain IN (#{Enum.map_join(domains, ", ", &"'#{&1}'")}) AND revision > 0 " <>
          "AND char_length(actor_ref) BETWEEN 1 AND 256 AND fingerprint ~ '^[0-9a-f]{64}$'"
    )
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
