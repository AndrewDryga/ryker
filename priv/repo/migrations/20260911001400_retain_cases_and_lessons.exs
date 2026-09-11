defmodule Responder.Repo.Migrations.RetainCasesAndLessons do
  use Ecto.Migration

  # Everything Responder learned from an incident used to expire with the raw
  # transcript that produced it, so a matching outage a year later started from
  # nothing. The compact case and the reviewed lesson are their own records
  # with their own lifetime: they hold no raw payload, they reference the
  # episode they came from rather than depending on its rows, and only explicit
  # deletion or supersession removes them.
  def up do
    create table(:episode_case_records, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:case_ref, :text, null: false)
      add(:episode_id, :uuid, null: false)
      add(:episode_key, :text, null: false)
      add(:execution_mode, :text, null: false)
      add(:transport, :text, null: false)
      add(:conversation_ref, :text, null: false)
      add(:workspace_ref, :text, null: false)
      add(:repository_ref, :text)
      add(:problem, :text, null: false)
      add(:occurrence_refs, {:array, :text}, null: false, default: [])
      add(:cause, :text)
      add(:attempted_actions, {:array, :text}, null: false, default: [])
      add(:outcome, :text)
      add(:links, {:array, :text}, null: false, default: [])
      add(:anchor_keys, {:array, :text}, null: false, default: [])
      add(:search_text, :text, null: false)
      add(:source_refs, {:array, :text}, null: false, default: [])
      add(:status, :text, null: false, default: "active")
      add(:closed_at, :utc_datetime_usec, null: false)
      add(:content_fingerprint, :text, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:episode_case_records, [:case_ref]))
    create(index(:episode_case_records, [:workspace_ref, :status]))
    create(index(:episode_case_records, [:conversation_ref]))
    create(index(:episode_case_records, [:anchor_keys], using: "GIN"))

    execute(
      "CREATE INDEX episode_case_record_search ON #{qualified("episode_case_records")} USING GIN (to_tsvector('simple', search_text))",
      "DROP INDEX #{qualified("episode_case_record_search")}"
    )

    create(
      constraint(:episode_case_records, :episode_case_record_valid,
        check:
          "status IN ('active', 'deleted') AND execution_mode IN ('live', 'shadow') AND " <>
            "char_length(case_ref) > 0 AND char_length(problem) BETWEEN 1 AND 4096 AND " <>
            "char_length(search_text) <= 16384 AND char_length(content_fingerprint) = 64 AND " <>
            "cardinality(occurrence_refs) <= 64 AND cardinality(attempted_actions) <= 32 AND " <>
            "cardinality(links) <= 32 AND cardinality(anchor_keys) <= 64 AND " <>
            "cardinality(source_refs) <= 64"
      )
    )

    create table(:episode_case_lessons, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:lesson_ref, :text, null: false)
      add(:case_id, :uuid, null: false)
      add(:workspace_ref, :text, null: false)
      add(:conditions, :text, null: false)
      add(:steps, :text, null: false)
      add(:verification, :text)
      add(:risks, :text)
      add(:status, :text, null: false, default: "draft")
      add(:reviewed_by_actor_ref, :text)
      add(:reviewed_at, :utc_datetime_usec)
      add(:review_ref, :text)
      add(:supersedes_lesson_id, :uuid)
      add(:anchor_keys, {:array, :text}, null: false, default: [])
      add(:search_text, :text, null: false)
      add(:source_refs, {:array, :text}, null: false, default: [])
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:episode_case_lessons, [:lesson_ref]))
    create(index(:episode_case_lessons, [:case_id]))
    create(index(:episode_case_lessons, [:workspace_ref, :status]))
    create(index(:episode_case_lessons, [:anchor_keys], using: "GIN"))

    execute(
      "CREATE INDEX episode_case_lesson_search ON #{qualified("episode_case_lessons")} USING GIN (to_tsvector('simple', search_text))",
      "DROP INDEX #{qualified("episode_case_lesson_search")}"
    )

    create(
      constraint(:episode_case_lessons, :episode_case_lesson_valid,
        check:
          "status IN ('draft', 'approved', 'superseded', 'removed') AND " <>
            "char_length(lesson_ref) > 0 AND char_length(conditions) BETWEEN 1 AND 4096 AND " <>
            "char_length(steps) BETWEEN 1 AND 8192 AND char_length(search_text) <= 16384 AND " <>
            "(status <> 'approved' OR (reviewed_by_actor_ref IS NOT NULL AND review_ref IS NOT NULL)) AND " <>
            "cardinality(anchor_keys) <= 64 AND cardinality(source_refs) <= 64"
      )
    )
  end

  def down do
    # A case and its reviewed lesson are the only remaining record of work whose
    # transcript has already been reclaimed; rolling them away would erase it.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("episode_case_records")} LIMIT 1)
         OR EXISTS (SELECT 1 FROM #{qualified("episode_case_lessons")} LIMIT 1) THEN
        RAISE EXCEPTION 'retained cases or lessons have data and cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    drop(table(:episode_case_lessons))
    drop(table(:episode_case_records))
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
