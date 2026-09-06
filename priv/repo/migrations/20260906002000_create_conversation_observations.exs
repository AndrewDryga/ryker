defmodule Responder.Repo.Migrations.CreateConversationObservations do
  use Ecto.Migration

  def change do
    # Derived memory has its own retention horizon; removing a source execution
    # must not silently cascade-delete what the bot learned from the conversation.
    create table(:conversation_observations, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:identity_key, :text, null: false)
      add(:transport, :text, null: false)
      add(:workspace_ref, :text, null: false)
      add(:conversation_ref, :text, null: false)
      add(:thread_ref, :text)
      add(:repository_ref, :text)
      add(:visibility, :text, null: false)
      add(:source_input_id, :uuid, null: false)
      add(:source_episode_id, :uuid)
      add(:source_message_ref, :text, null: false)
      add(:source_result_ref, :text, null: false)
      add(:source_fingerprint, :text, null: false)
      add(:actor_ref, :text, null: false)
      add(:execution_mode, :text, null: false)
      add(:revision, :bigint, null: false)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:note, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:conversation_observations, [:identity_key]))

    create(
      index(:conversation_observations, [:workspace_ref, :conversation_ref, :occurred_at],
        name: :conversation_observations_scope_time
      )
    )

    create(index(:conversation_observations, [:updated_at]))

    create(
      constraint(:conversation_observations, :conversation_observations_revision_positive,
        check: "revision > 0"
      )
    )

    execute(
      """
      CREATE TRIGGER responder_control_plane_changed
      AFTER INSERT OR UPDATE OR DELETE ON #{qualified("conversation_observations")}
      FOR EACH STATEMENT EXECUTE FUNCTION #{qualified("responder_control_plane_notify")}()
      """,
      "DROP TRIGGER responder_control_plane_changed ON #{qualified("conversation_observations")}"
    )

    execute("SELECT 1", """
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("conversation_observations")} LIMIT 1) THEN
        RAISE EXCEPTION 'conversation observations have data and cannot be rolled back safely';
      END IF;
    END $$;
    """)
  end

  defp qualified(table),
    do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}".#{table})
end
