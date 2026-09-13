defmodule Ryker.Repo.Migrations.CreateConversationKnowledge do
  use Ecto.Migration

  def change do
    alter table(:conversation_observations) do
      modify(:source_result_ref, :text, null: true, from: {:text, null: false})
      add(:source_dependencies, :text)
    end

    create table(:conversation_knowledge, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:scope_key, :text, null: false)
      add(:topic_key, :text, null: false)
      add(:transport, :text, null: false)
      add(:workspace_ref, :text, null: false)
      add(:conversation_ref, :text, null: false)
      add(:repository_ref, :text)
      add(:visibility, :text, null: false)
      add(:state, :text, null: false)
      add(:version, :bigint, null: false)
      add(:source_generation, :bigint, null: false)
      add(:source_dependencies, :text, null: false)
      add(:source_input_id, :uuid, null: false)
      add(:source_episode_id, :uuid)
      add(:latest_source_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:conversation_knowledge, [:scope_key, :topic_key]))
    create(index(:conversation_knowledge, [:workspace_ref, :conversation_ref, :updated_at]))

    create(
      index(:conversation_knowledge, ["to_tsvector('simple', state)"],
        using: :gin,
        name: :conversation_knowledge_search
      )
    )

    create(constraint(:conversation_knowledge, :knowledge_version_positive, check: "version > 0"))

    create table(:conversation_knowledge_sources, primary_key: false) do
      add(:knowledge_id, references(:conversation_knowledge, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      # No FK to observations: a pruned or deleted source must invalidate the
      # aggregate, not silently remove the dependency that makes it unsafe.
      add(:observation_id, :uuid, primary_key: true)
      add(:generation, :bigint, primary_key: true)
      add(:source_revision, :bigint, null: false)
      add(:source_fingerprint, :text, null: false)
      add(:source_note, :text)
      add(:retained_at, :utc_datetime_usec, null: false)
      add(:introduced_version, :bigint, null: false)
    end

    create table(:conversation_knowledge_revisions, primary_key: false) do
      add(:knowledge_id, references(:conversation_knowledge, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:version, :bigint, primary_key: true)
      add(:source_generation, :bigint, null: false)
      add(:source_dependencies, :text, null: false)
      add(:state, :text, null: false)
      add(:source_input_id, :uuid, null: false)
      add(:source_result_ref, :text, null: false)
      add(:source_at, :utc_datetime_usec, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(index(:conversation_knowledge, [:updated_at]))

    create table(:episode_work_knowledge_exposures, primary_key: false) do
      add(:session_id, references(:episode_work_sessions, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      # Deliberately no knowledge FK: deleting knowledge must withdraw, not erase, the exposure fence.
      add(:knowledge_id, :uuid, primary_key: true)
      add(:version, :bigint, primary_key: true)
      add(:turn_id, :uuid, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create table(:episode_work_source_exposures, primary_key: false) do
      add(:session_id, references(:episode_work_sessions, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:observation_id, :uuid, primary_key: true)
      add(:source_input_id, :uuid, primary_key: true)
      add(:receipt, :text, null: false)
    end

    for name <- [:conversation_summaries, :conversation_rollups] do
      alter table(name) do
        add(:source_dependencies, :text, default: "[]")
      end
    end

    execute("SELECT 1", """
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("conversation_knowledge")} LIMIT 1)
        OR EXISTS (SELECT 1 FROM #{qualified("episode_work_knowledge_exposures")} LIMIT 1)
        OR EXISTS (SELECT 1 FROM #{qualified("episode_work_source_exposures")} LIMIT 1)
        OR EXISTS (SELECT 1 FROM #{qualified("conversation_observations")}
                   WHERE source_dependencies IS NOT NULL OR source_result_ref IS NULL LIMIT 1)
        OR EXISTS (SELECT 1 FROM #{qualified("conversation_summaries")}
                   WHERE source_dependencies::jsonb <> '[]'::jsonb LIMIT 1)
        OR EXISTS (SELECT 1 FROM #{qualified("conversation_rollups")}
                   WHERE source_dependencies::jsonb <> '[]'::jsonb LIMIT 1) THEN
        RAISE EXCEPTION 'conversation learning has data and cannot be rolled back safely';
      END IF;
    END $$;
    """)
  end

  defp qualified(table), do: ~s("#{String.replace(prefix() || "public", "\"", "\"\"")}".#{table})
end
