defmodule Responder.Repo.Migrations.AddEpisodeOriginsAndCorrelationClaims do
  use Ecto.Migration

  # One episode may gather evidence from several conversations. Every admitted
  # input keeps the exact place it came from, so answers return there and
  # routing can weigh thread gravity per message instead of per episode. The
  # episode destination stays the one progress home. Trusted occurrence
  # identities become scoped claims so two channels cannot create duplicate
  # active work for one occurrence.
  @origin_kinds "origin_kind IN ('channel_root', 'thread_reply', 'conversation')"

  def up do
    create table(:episode_input_origins, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :episode_id,
        references(:episode_kernel_episodes, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:input_ref, :text, null: false)
      add(:sequence, :bigint, null: false)
      add(:native_input_id, :text, null: false)
      add(:revision, :bigint, null: false)
      add(:source_kind, :text)
      add(:source_ref, :text)
      add(:source_item_ref, :text)
      add(:actor_ref, :text, null: false)
      add(:transport, :text, null: false)
      add(:conversation_ref, :text, null: false)
      add(:thread_ref, :text)
      add(:origin_kind, :text, null: false)
      add(:root_ref, :text)
      add(:occurred_at, :utc_datetime_usec, null: false)
      add(:effective, :boolean, null: false, default: true)
      add(:correction_ref, :text)
      add(:inserted_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:episode_input_origins, [:episode_id, :input_ref]))
    create(index(:episode_input_origins, [:episode_id, :sequence]))
    create(index(:episode_input_origins, [:native_input_id]))

    create(
      index(:episode_input_origins, [:transport, :conversation_ref, :thread_ref, :occurred_at],
        name: :episode_input_origin_thread_chronology
      )
    )

    create(
      constraint(:episode_input_origins, :episode_input_origin_valid,
        check:
          "char_length(input_ref) > 0 AND sequence > 0 AND revision > 0 AND " <>
            "char_length(actor_ref) > 0 AND char_length(transport) > 0 AND " <>
            "char_length(conversation_ref) > 0 AND #{@origin_kinds} AND " <>
            "(effective OR correction_ref IS NOT NULL)"
      )
    )

    create table(:episode_correlation_claims, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :episode_id,
        references(:episode_kernel_episodes, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:input_ref, :text, null: false)
      add(:scope_ref, :text, null: false)
      add(:namespace, :text, null: false)
      add(:occurrence_ref, :text, null: false)
      add(:lifecycle_state, :text, null: false, default: "active")
      add(:status, :text, null: false, default: "active")
      add(:established_at, :utc_datetime_usec, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:episode_correlation_claims, [:scope_ref, :namespace, :occurrence_ref],
        name: :episode_correlation_claim_owner,
        where: "status = 'active'"
      )
    )

    create(index(:episode_correlation_claims, [:episode_id]))

    create(
      constraint(:episode_correlation_claims, :episode_correlation_claim_valid,
        check:
          "char_length(input_ref) > 0 AND char_length(scope_ref) > 0 AND " <>
            "char_length(namespace) > 0 AND char_length(occurrence_ref) BETWEEN 1 AND 512 AND " <>
            "lifecycle_state IN ('active', 'terminal') AND status IN ('active', 'retired')"
      )
    )

    # Backfill every retained admitted input from its immutable event. The
    # input's own destination is inside the event payload; the command-level
    # destination is the episode home and only stands in for custom payloads
    # that carried no source destination. A Slack root binds its own timestamp
    # as thread, so root and reply are told apart from retained identities
    # alone; nothing else is guessed.
    execute("""
    INSERT INTO #{qualified("episode_input_origins")} (
      id, episode_id, input_ref, sequence, native_input_id, revision, source_kind, source_ref,
      source_item_ref, actor_ref, transport, conversation_ref, thread_ref, origin_kind, root_ref,
      occurred_at, effective, correction_ref, inserted_at
    )
    SELECT
      gen_random_uuid(),
      event.episode_id,
      event.dedupe_key,
      event.sequence,
      event.doc ->> 'native_input_id',
      (event.doc ->> 'revision')::bigint,
      event.doc -> 'payload' -> 'source' ->> 'kind',
      event.doc -> 'payload' -> 'source' ->> 'ref',
      event.doc -> 'payload' ->> 'source_item_ref',
      event.doc ->> 'actor_ref',
      COALESCE(event.doc -> 'payload' -> 'destination' ->> 'transport', event.doc -> 'destination' ->> 'transport'),
      COALESCE(event.doc -> 'payload' -> 'destination' ->> 'conversation_ref', event.doc -> 'destination' ->> 'conversation_ref'),
      CASE
        WHEN event.doc -> 'payload' -> 'destination' IS NOT NULL THEN event.doc -> 'payload' -> 'destination' ->> 'thread_ref'
        ELSE event.doc -> 'destination' ->> 'thread_ref'
      END,
      CASE
        WHEN event.doc -> 'payload' -> 'source' ->> 'kind' = 'slack'
          AND event.doc -> 'payload' ->> 'source_item_ref' IS NOT NULL
          AND event.doc -> 'payload' -> 'destination' ->> 'thread_ref' = event.doc -> 'payload' ->> 'source_item_ref'
          THEN 'channel_root'
        WHEN event.doc -> 'payload' -> 'source' ->> 'kind' = 'slack'
          AND event.doc -> 'payload' ->> 'source_item_ref' IS NOT NULL
          AND event.doc -> 'payload' -> 'destination' ->> 'thread_ref' IS NOT NULL
          THEN 'thread_reply'
        ELSE 'conversation'
      END,
      CASE
        WHEN event.doc -> 'payload' -> 'source' ->> 'kind' = 'slack'
          AND event.doc -> 'payload' ->> 'source_item_ref' IS NOT NULL
          THEN event.doc -> 'payload' -> 'destination' ->> 'thread_ref'
        ELSE NULL
      END,
      event.occurred_at,
      true,
      NULL,
      clock_timestamp()
    FROM (
      SELECT episode_id, dedupe_key, sequence, occurred_at, payload::jsonb AS doc
      FROM #{qualified("episode_kernel_events")}
      WHERE kind = 'input_admitted'
    ) AS event
    WHERE event.doc ->> 'native_input_id' IS NOT NULL
      AND event.doc ->> 'actor_ref' IS NOT NULL
      AND COALESCE(event.doc -> 'payload' -> 'destination' ->> 'transport', event.doc -> 'destination' ->> 'transport') IS NOT NULL
      AND COALESCE(event.doc -> 'payload' -> 'destination' ->> 'conversation_ref', event.doc -> 'destination' ->> 'conversation_ref') IS NOT NULL
    ON CONFLICT (episode_id, input_ref) DO NOTHING
    """)
  end

  def down do
    # Origins are rebuilt from the event ledger, but a correction that moved an
    # input elsewhere and a claimed occurrence identity exist nowhere else.
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified("episode_input_origins")} WHERE NOT effective LIMIT 1
      ) OR EXISTS (
        SELECT 1 FROM #{qualified("episode_correlation_claims")} LIMIT 1
      ) THEN
        RAISE EXCEPTION 'episode association corrections or correlation claims have data and cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    drop(table(:episode_correlation_claims))
    drop(table(:episode_input_origins))
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
