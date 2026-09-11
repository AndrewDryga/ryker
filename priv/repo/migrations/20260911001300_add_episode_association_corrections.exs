defmodule Responder.Repo.Migrations.AddEpisodeAssociationCorrections do
  use Ecto.Migration

  # Routing can be wrong, and the fix cannot be a rewrite: an operator-confirmed
  # merge, split or reassignment retires a mistaken owner and records why,
  # leaving the immutable history that produced it exactly where it is.
  def up do
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
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("episode_association_corrections")} LIMIT 1) THEN
        RAISE EXCEPTION 'association corrections have data and cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    drop(table(:episode_association_corrections))
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
