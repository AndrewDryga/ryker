defmodule Ryker.Repo.Migrations.CreateInputArtifactReferences do
  use Ecto.Migration

  def up do
    create table(:ingress_input_artifact_references, primary_key: false) do
      add(
        :input_id,
        references(:ingress_inbox_entries, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:artifact_id, references(:input_artifacts, type: :binary_id, on_delete: :restrict),
        null: false,
        primary_key: true
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:ingress_input_artifact_references, [:artifact_id]))

    create table(:work_input_artifact_references, primary_key: false) do
      add(:turn_id, references(:episode_work_turns, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:artifact_id, references(:input_artifacts, type: :binary_id, on_delete: :restrict),
        null: false,
        primary_key: true
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:work_input_artifact_references, [:artifact_id]))

    execute("""
    INSERT INTO ingress_input_artifact_references
      (input_id, artifact_id, inserted_at, updated_at)
    SELECT input.id, artifact.id, clock_timestamp(), clock_timestamp()
    FROM ingress_inbox_entries AS input
    JOIN input_artifacts AS artifact ON strpos(input.content, artifact.ref) > 0
    ON CONFLICT DO NOTHING
    """)

    execute("""
    INSERT INTO work_input_artifact_references
      (turn_id, artifact_id, inserted_at, updated_at)
    SELECT turn.id, artifact.id, clock_timestamp(), clock_timestamp()
    FROM episode_work_turns AS turn
    JOIN input_artifacts AS artifact
      ON strpos(COALESCE(turn.submission, ''), artifact.ref) > 0
    ON CONFLICT DO NOTHING
    """)
  end

  def down do
    drop(table(:work_input_artifact_references))
    drop(table(:ingress_input_artifact_references))
  end
end
