defmodule Ryker.Repo.Migrations.RetireAssociationCorrections do
  use Ecto.Migration

  # Operator-confirmed merges, splits and reassignments of which episode an
  # input belongs to lost their last caller: nothing in the product records
  # one, and the only readers were a candidate-search filter and an episode
  # trace step that could never find a row. The live table held zero rows on
  # 2026-09-26, so retiring it drops nothing.
  #
  # Dropping a table is the one step a rollback cannot undo, so the migration
  # refuses to run over a populated table rather than discard history silently.
  # `down` recreates it empty, exactly as it stood, so the migration that
  # created it still finds every object its own rollback expects.
  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("episode_association_corrections")} LIMIT 1) THEN
        RAISE EXCEPTION 'episode_association_corrections has data; dropping it would discard history';
      END IF;
    END
    $$
    """)

    drop(table(:episode_association_corrections))
  end

  def down do
    create table(:episode_association_corrections, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:kind, :text, null: false)
      add(:source_episode_id, :uuid, null: false)
      add(:target_episode_id, :uuid)
      add(:input_refs, {:array, :text}, null: false, default: [])
      add(:actor_ref, :text, null: false)
      add(:confirmation_ref, :text, null: false)
      add(:reason, :text, null: false)
      add(:applied_at, :utc_datetime_usec, null: false)
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create(unique_index(:episode_association_corrections, [:confirmation_ref]))
    create(index(:episode_association_corrections, [:source_episode_id]))
    create(index(:episode_association_corrections, [:target_episode_id]))

    create(
      constraint(:episode_association_corrections, :episode_association_correction_valid,
        check:
          "kind IN ('merge', 'split', 'reassign') AND char_length(actor_ref) > 0 AND " <>
            "char_length(confirmation_ref) > 0 AND char_length(reason) BETWEEN 1 AND 2048 AND " <>
            "cardinality(input_refs) <= 200 AND " <>
            "(kind = 'split' OR target_episode_id IS NOT NULL) AND " <>
            "(target_episode_id IS NULL OR target_episode_id <> source_episode_id)"
      )
    )

    # The table notified the control plane of a change, as every table does.
    execute("""
    CREATE TRIGGER ryker_control_plane_changed
    AFTER INSERT OR UPDATE OR DELETE ON #{qualified("episode_association_corrections")}
    FOR EACH STATEMENT EXECUTE FUNCTION #{qualified("ryker_control_plane_notify")}()
    """)
  end

  defp qualified(name) do
    case prefix() do
      nil -> name
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{name})
    end
  end
end
