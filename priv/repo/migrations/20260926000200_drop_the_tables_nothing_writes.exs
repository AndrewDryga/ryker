defmodule Ryker.Repo.Migrations.DropTheTablesNothingWrites do
  use Ecto.Migration

  # Four tables outlived their writers. The Card Lab was retired on 2026-09-13
  # and its feedback and post receipts had no reader left; the participation
  # overrides were folded into channel configurations by an importer that is
  # gone; case lessons never gained a product path that drafted or approved
  # one. Every one held zero rows on 2026-09-25, so retiring them drops nothing.
  #
  # Dropping a table is the one step a rollback cannot undo, so the migration
  # refuses to run over a populated table rather than discard history silently.
  # `down` recreates each table empty, exactly as it stood, so the ladder of
  # older migrations still finds every object their own rollbacks expect.
  @tables ~w(card_lab_feedback card_lab_posts episode_case_lessons slack_channel_setting_overrides)

  def up do
    refuse_populated_tables()

    for table <- @tables do
      drop(table(table))
    end
  end

  def down do
    create table(:card_lab_feedback, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:actor_ref, :text, null: false)
      add(:card_id, :text, null: false)
      add(:state_id, :text, null: false)
      add(:verdict, :text, null: false)
      add(:note, :text, null: false)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:card_lab_feedback, [:card_id, :state_id, :inserted_at]))

    create(
      constraint(:card_lab_feedback, :card_lab_feedback_valid,
        check: """
        char_length(actor_ref) BETWEEN 1 AND 1024 AND
        char_length(card_id) BETWEEN 1 AND 120 AND
        char_length(state_id) BETWEEN 1 AND 120 AND
        verdict IN ('needs_work', 'good', 'approved') AND
        octet_length(note) BETWEEN 1 AND 4000
        """
      )
    )

    create table(:card_lab_posts, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:workspace_ref, :text, null: false)
      add(:channel_ref, :text, null: false)
      add(:channel_name, :text, null: false)
      add(:card_id, :text, null: false)
      add(:state_id, :text, null: false)
      add(:payload, :text, null: false)
      add(:fingerprint, :text, null: false)
      add(:request_fingerprint, :text, null: false)
      add(:revision, :bigint, null: false, default: 1)
      add(:delivered_state_id, :text)
      add(:delivered_fingerprint, :text)
      add(:message_ref, :text)
      add(:status, :text, null: false, default: "pending")
      add(:attempt_count, :integer, null: false, default: 0)
      add(:lease_ref, :uuid)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:next_attempt_at, :utc_datetime_usec, null: false)
      add(:last_error, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:card_lab_posts, [:workspace_ref, :status, :next_attempt_at]))
    create(index(:card_lab_posts, [:card_id, :inserted_at]))

    create(
      constraint(:card_lab_posts, :card_lab_posts_valid,
        check: """
        status IN ('pending', 'posted', 'blocked') AND revision > 0 AND attempt_count >= 0 AND
        workspace_ref ~ '^T[A-Z0-9]+$' AND channel_ref ~ '^[CG][A-Z0-9]+$' AND
        octet_length(card_id) BETWEEN 1 AND 120 AND octet_length(state_id) BETWEEN 1 AND 120 AND
        fingerprint ~ '^[0-9a-f]{64}$' AND request_fingerprint ~ '^[0-9a-f]{64}$' AND
        (message_ref IS NULL OR message_ref ~ '^[0-9]+[.][0-9]+$') AND
        ((lease_ref IS NULL) = (lease_expires_at IS NULL)) AND
        (status <> 'posted' OR (message_ref IS NOT NULL AND delivered_fingerprint = fingerprint))
        """
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
      "CREATE INDEX episode_case_lesson_search ON #{qualified("episode_case_lessons")} USING GIN (to_tsvector('simple', search_text))"
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

    create table(:slack_channel_setting_overrides, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:workspace_ref, :text, null: false)
      add(:scope_kind, :text, null: false)
      add(:scope_ref, :text, null: false)
      add(:setting, :text, null: false)
      add(:value, :boolean, null: false)
      add(:actor_ref, :text, null: false)
      add(:event_ref, :text, null: false)
      add(:revision, :bigint, null: false, default: 1)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(
        :slack_channel_setting_overrides,
        [:workspace_ref, :scope_kind, :scope_ref, :setting],
        name: :slack_channel_setting_identity
      )
    )

    create(index(:slack_channel_setting_overrides, [:workspace_ref, :updated_at]))

    create(
      constraint(:slack_channel_setting_overrides, :slack_channel_setting_override_valid,
        check: """
        char_length(workspace_ref) BETWEEN 1 AND 256 AND
        scope_kind IN ('channel', 'workspace') AND
        char_length(scope_ref) BETWEEN 1 AND 1024 AND
        setting IN ('proactive', 'shadow') AND
        char_length(actor_ref) BETWEEN 1 AND 1024 AND
        char_length(event_ref) BETWEEN 1 AND 1024 AND
        revision > 0
        """
      )
    )

    # Every table notifies the control plane of a change, as these did before.
    for table <- @tables do
      execute("""
      CREATE TRIGGER ryker_control_plane_changed
      AFTER INSERT OR UPDATE OR DELETE ON #{qualified(table)}
      FOR EACH STATEMENT EXECUTE FUNCTION #{qualified("ryker_control_plane_notify")}()
      """)
    end
  end

  defp refuse_populated_tables do
    for table <- @tables do
      execute("""
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM #{qualified(table)} LIMIT 1) THEN
          RAISE EXCEPTION '#{table} has data; dropping it would discard history';
        END IF;
      END
      $$
      """)
    end
  end

  defp qualified(name) do
    case prefix() do
      nil -> name
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{name})
    end
  end
end
