defmodule Responder.Retention.Data do
  alias Responder.Work.ActivityRetention

  @moduledoc """
  Ownership-aware PostgreSQL data pruning.

  Operational payloads are redacted only after every Coop session owned by an
  episode is proven discarded. Episode history is removed as one coherent
  unit, never event-by-event, and compact custody receipts survive until the
  audit horizon. Every age comparison uses PostgreSQL time.
  """

  alias Responder.Repo
  alias Responder.State.{Continuity, KnowledgeRetention, Learning, Memories}

  @advisory_lock 7_152_019_552_843_111
  @terminal_episode_states ~w(complete cancelled)
  @terminal_turn_states ~w(settled superseded)
  @terminal_schedule_states ~w(completed expired deleted)
  @summary_compaction_seconds 7 * 86_400
  @memory_review_seconds 30 * 86_400

  @type result :: %{
          audit_episodes: non_neg_integer(),
          audit_rows: non_neg_integer(),
          closed_work: non_neg_integer(),
          configuration_sessions: non_neg_integer(),
          conversation_memory: non_neg_integer(),
          cutover_items: non_neg_integer(),
          delivery_reactions: non_neg_integer(),
          episode_histories: non_neg_integer(),
          input_artifacts: non_neg_integer(),
          operational_inputs: non_neg_integer(),
          operational_turns: non_neg_integer(),
          output_artifacts: non_neg_integer(),
          schedule_runs: non_neg_integer(),
          standing_runs: non_neg_integer(),
          worker_commands: non_neg_integer(),
          worker_events: non_neg_integer()
        }

  @spec prune(map() | keyword()) :: {:ok, result() | :busy} | {:error, term()}
  def prune(settings) do
    with {:ok, settings} <- settings(settings) do
      Repo.checkout(fn -> prune_with_lock(settings) end)
    end
  end

  defp prune_with_lock(settings) do
    if advisory_lock?() do
      try do
        prune_in_transactions(settings)
      after
        release_advisory_lock!()
      end
    else
      {:ok, :busy}
    end
  end

  defp prune_in_transactions(settings) do
    with {:ok, expiring} <-
           Repo.transaction(fn -> prune_expiring_resources(empty_result(), settings) end),
         {:ok, operational} <-
           Repo.transaction(fn -> prune_operational(expiring, settings) end),
         {:ok, closed_work} <-
           Repo.transaction(fn -> prune_closed_work(operational, settings) end),
         {:ok, history} <- Repo.transaction(fn -> prune_history(closed_work, settings) end) do
      Repo.transaction(fn -> prune_audit(history, settings) end)
    end
  end

  defp prune_expiring_resources(result, settings) do
    {:ok, _reviews_created} =
      Memories.refresh_all_reviews_in_transaction(
        min(settings.conversation_memory_seconds, @memory_review_seconds)
      )

    {:ok, compacted} =
      Continuity.compact_in_transaction(
        min(settings.conversation_memory_seconds, @summary_compaction_seconds),
        settings.conversation_memory_seconds
      )

    memory =
      execute_count(
        """
        WITH candidates AS (
          SELECT id
          FROM operational_memory_entries
          WHERE expires_at <= clock_timestamp()
             OR ((scope_kind <> 'global' OR status <> 'active') AND
                 updated_at < clock_timestamp() - ($1 * interval '1 second'))
          ORDER BY updated_at, id
          LIMIT 100
          FOR UPDATE SKIP LOCKED
        )
        DELETE FROM operational_memory_entries AS memory
        USING candidates
        WHERE memory.id = candidates.id
        """,
        [settings.conversation_memory_seconds]
      )

    rollups =
      execute_count("""
      WITH candidates AS (
        SELECT id
        FROM conversation_rollups
        WHERE expires_at <= clock_timestamp()
        ORDER BY expires_at, id
        LIMIT 100
        FOR UPDATE SKIP LOCKED
      )
      DELETE FROM conversation_rollups AS rollup
      USING candidates
      WHERE rollup.id = candidates.id
      """)

    _drafts =
      execute_count(
        """
        WITH candidates AS (
          SELECT draft.id
          FROM conversation_summary_drafts AS draft
          JOIN episode_work_turns AS turn ON turn.id = draft.turn_id
          WHERE turn.status IN ('settled', 'superseded')
            AND draft.updated_at < clock_timestamp() - ($1 * interval '1 second')
          ORDER BY draft.updated_at, draft.id
          LIMIT 100
          FOR UPDATE OF draft SKIP LOCKED
        )
        DELETE FROM conversation_summary_drafts AS draft
        USING candidates
        WHERE draft.id = candidates.id
        """,
        [settings.operational_data_seconds]
      )

    _behaviors =
      execute_count("""
      WITH candidates AS (
        SELECT id
        FROM operator_behaviors
        WHERE expires_at <= clock_timestamp()
        ORDER BY expires_at, id
        LIMIT 100
        FOR UPDATE SKIP LOCKED
      )
      DELETE FROM operator_behaviors AS behavior
      USING candidates
      WHERE behavior.id = candidates.id
      """)

    :ok = Memories.dismiss_invalid_reviews_in_transaction()

    _schedules =
      execute_count(
        """
        WITH candidates AS (
          SELECT id
          FROM episode_schedules
          WHERE status = ANY($1)
            AND updated_at < clock_timestamp() - ($2 * interval '1 second')
            AND NOT EXISTS (
              SELECT 1
              FROM episode_schedule_occurrences AS occurrence
              WHERE occurrence.schedule_id = episode_schedules.id
            )
          ORDER BY updated_at, id
          LIMIT 100
          FOR UPDATE SKIP LOCKED
        )
        DELETE FROM episode_schedules AS schedule
        USING candidates
        WHERE schedule.id = candidates.id
        """,
        [@terminal_schedule_states, settings.episode_history_seconds]
      )

    observations =
      execute_count(
        """
        WITH candidates AS (
          SELECT id FROM conversation_observations
          WHERE note IS NOT NULL
            AND updated_at < clock_timestamp() - ($1 * interval '1 second')
          ORDER BY updated_at, id LIMIT 100 FOR UPDATE SKIP LOCKED
        )
        UPDATE conversation_observations AS note SET note = NULL FROM candidates
        WHERE note.id = candidates.id
        """,
        [settings.conversation_memory_seconds]
      )

    knowledge =
      KnowledgeRetention.prune_in_transaction(settings.conversation_memory_seconds)

    %{result | conversation_memory: memory + compacted + rollups + observations + knowledge}
  end

  defp prune_operational(result, settings) do
    cutoff = settings.operational_data_seconds

    _slack_thread_statuses =
      execute_count(
        """
        WITH candidates AS (
          SELECT id
          FROM slack_thread_statuses
          WHERE status = 'delivered'
            AND desired_text = ''
            AND updated_at < clock_timestamp() - ($1 * interval '1 second')
          ORDER BY updated_at, id
          LIMIT 100
          FOR UPDATE SKIP LOCKED
        )
        DELETE FROM slack_thread_statuses AS status
        USING candidates
        WHERE status.id = candidates.id
        """,
        [cutoff]
      )

    _worker_enrollment_tokens =
      execute_count(
        """
        WITH candidates AS (
          SELECT id
          FROM coop_worker_enrollment_tokens
          WHERE (consumed_at IS NOT NULL OR expires_at <= clock_timestamp())
            AND inserted_at < clock_timestamp() - ($1 * interval '1 second')
          ORDER BY inserted_at, id
          LIMIT 100
          FOR UPDATE SKIP LOCKED
        )
        DELETE FROM coop_worker_enrollment_tokens AS token
        USING candidates
        WHERE token.id = candidates.id
        """,
        [cutoff]
      )

    worker_commands =
      execute_count(
        """
        WITH candidates AS (
          SELECT command.id
          FROM coop_worker_commands AS command
          JOIN episode_work_sessions AS session ON session.id = command.session_id
          WHERE command.status IN ('succeeded', 'failed')
            AND command.updated_at < clock_timestamp() - ($1 * interval '1 second')
            AND session.cleanup_status = 'discarded'
          ORDER BY command.updated_at, command.id
          LIMIT 100
          FOR UPDATE OF command SKIP LOCKED
        )
        DELETE FROM coop_worker_commands AS command
        USING candidates
        WHERE command.id = candidates.id
        """,
        [cutoff]
      )

    worker_events =
      execute_count(
        """
        WITH candidates AS (
          SELECT event.id
          FROM coop_worker_events AS event
          JOIN episode_work_sessions AS session ON session.id = event.session_id
          WHERE event.inserted_at < clock_timestamp() - ($1 * interval '1 second')
            AND session.cleanup_status = 'discarded'
          ORDER BY event.inserted_at, event.id
          LIMIT 100
          FOR UPDATE OF event SKIP LOCKED
        )
        DELETE FROM coop_worker_events AS event
        USING candidates
        WHERE event.id = candidates.id
        """,
        [cutoff]
      )

    _non_work_sessions =
      execute_count(
        """
        WITH candidates AS (
          SELECT session.id
          FROM episode_work_sessions AS session
          WHERE session.execution_kind IN ('admission', 'learning')
            AND session.cleanup_status = 'discarded'
            AND NOT session.activity_sync_pending
            AND session.updated_at < clock_timestamp() - ($1 * interval '1 second')
            AND NOT EXISTS (
              SELECT 1 FROM coop_worker_commands command
              WHERE command.session_id = session.id
            )
            AND NOT EXISTS (
              SELECT 1 FROM coop_worker_events event
              WHERE event.session_id = session.id
            )
            AND NOT EXISTS (
              SELECT 1 FROM episode_work_activity activity
              WHERE activity.session_id = session.id AND activity.operational_pruned_at IS NULL
            )
          ORDER BY session.updated_at, session.id
          LIMIT 100
          FOR UPDATE OF session SKIP LOCKED
        ), retired_activity AS (
          DELETE FROM episode_work_activity AS activity
          USING candidates WHERE activity.session_id = candidates.id
          RETURNING activity.session_id
        ), retired_placements AS (
          DELETE FROM coop_session_placements AS placement
          USING candidates
          WHERE placement.session_id = candidates.id
          RETURNING placement.session_id
        )
        DELETE FROM episode_work_sessions AS session
        USING candidates
        WHERE session.id = candidates.id
        """,
        [cutoff]
      )

    reactions =
      execute_count(
        """
        WITH candidates AS (
          SELECT id
          FROM delivery_reactions
          WHERE status = 'delivered'
            AND updated_at < clock_timestamp() - ($1 * interval '1 second')
          ORDER BY updated_at, id
          LIMIT 100
          FOR UPDATE SKIP LOCKED
        )
        DELETE FROM delivery_reactions AS reaction
        USING candidates
        WHERE reaction.id = candidates.id
        """,
        [cutoff]
      )

    configuration_sessions =
      execute_count(
        """
        WITH candidates AS (
          SELECT id
          FROM slack_configuration_sessions
          WHERE (
            status = ANY($1)
            AND updated_at < clock_timestamp() - ($2 * interval '1 second')
          ) OR expires_at < clock_timestamp() - ($2 * interval '1 second')
          ORDER BY updated_at, id
          LIMIT 100
          FOR UPDATE SKIP LOCKED
        )
        DELETE FROM slack_configuration_sessions AS session
        USING candidates
        WHERE session.id = candidates.id
        """,
        [~w(saved cancelled expired), cutoff]
      )

    operational_inputs =
      execute_count(
        """
        WITH candidates AS (
          SELECT input.id
          FROM ingress_inbox_entries AS input
          WHERE input.operational_pruned_at IS NULL
            AND input.status = ANY($1)
            AND input.updated_at < clock_timestamp() - ($2 * interval '1 second')
            AND NOT EXISTS (
              SELECT 1 FROM delivery_reactions reaction
              WHERE reaction.input_id = input.id AND reaction.status <> 'delivered'
            )
            AND (
              input.episode_id IS NULL
              OR NOT EXISTS (
                SELECT 1 FROM episode_work_sessions session
                WHERE session.episode_id = input.episode_id
                  AND session.cleanup_status <> 'discarded'
              )
            )
          ORDER BY input.updated_at, input.id
          LIMIT 100
          FOR UPDATE OF input SKIP LOCKED
        )
        UPDATE ingress_inbox_entries AS input
        SET content = '{"retention":"pruned"}',
            admission_context = NULL,
            admission_context_fingerprint = NULL,
            decision_document = '{"retention":"pruned"}',
            operational_pruned_at = clock_timestamp()
        FROM candidates
        WHERE input.id = candidates.id
        """,
        [~w(decided superseded), cutoff]
      )

    learning_artifacts = Learning.prune_in_transaction(settings.conversation_memory_seconds)

    _admission_artifacts =
      execute_count("""
      WITH candidates AS (
        SELECT attempt.id FROM admission_attempts attempt
        JOIN ingress_inbox_entries input ON input.id = attempt.input_id
        WHERE attempt.operational_pruned_at IS NULL AND input.operational_pruned_at IS NOT NULL
        ORDER BY attempt.inserted_at, attempt.id LIMIT 100
        FOR UPDATE OF attempt SKIP LOCKED
      )
      UPDATE admission_attempts attempt
      SET submission = CASE WHEN submission IS NULL THEN NULL ELSE '{"retention":"pruned"}' END,
          response = CASE WHEN response IS NULL THEN NULL ELSE '{"retention":"pruned"}' END,
          operational_pruned_at = clock_timestamp()
      FROM candidates WHERE attempt.id = candidates.id
      """)

    _status_receipts =
      execute_count(
        """
        DELETE FROM slack_thread_status_receipts WHERE id IN (
          SELECT id FROM slack_thread_status_receipts
          WHERE inserted_at < clock_timestamp() - ($1 * interval '1 second')
          ORDER BY inserted_at LIMIT 1000
        )
        """,
        [cutoff]
      )

    operational_turns =
      execute_count(
        """
        WITH candidates AS (
          SELECT turn.id, clock_timestamp() AS pruned_at
          FROM episode_work_turns AS turn
          JOIN episode_work_sessions AS session ON session.id = turn.session_id
          WHERE turn.operational_pruned_at IS NULL
            AND turn.status = ANY($1)
            AND turn.updated_at < clock_timestamp() - ($2 * interval '1 second')
            AND session.cleanup_status = 'discarded'
          ORDER BY turn.updated_at, turn.id
          LIMIT 100
          FOR UPDATE OF turn SKIP LOCKED
        ), response_bodies AS (
          UPDATE work_candidate_responses AS response
          SET body = NULL, operational_pruned_at = candidates.pruned_at
          FROM candidates
          WHERE response.turn_id = candidates.id
            AND response.operational_pruned_at IS NULL
          RETURNING response.turn_id
        )
        UPDATE episode_work_turns AS turn
        SET submission = CASE WHEN submission IS NULL THEN NULL ELSE '{"retention":"pruned"}' END,
            candidate = CASE WHEN candidate IS NULL THEN NULL ELSE '{"retention":"pruned"}' END,
            validation_intent = CASE WHEN validation_intent IS NULL THEN NULL ELSE '{"retention":"pruned"}' END,
            completion_receipt = NULL,
            cancellation_intent = CASE WHEN cancellation_intent IS NULL THEN NULL ELSE '{"retention":"pruned"}' END,
            delivery_document = CASE WHEN delivery_document IS NULL THEN NULL ELSE '{"retention":"pruned"}' END,
            continuation = CASE WHEN continuation IS NULL THEN NULL ELSE '{"retention":"pruned"}' END,
            operational_pruned_at = candidates.pruned_at
        FROM candidates
        WHERE turn.id = candidates.id
        """,
        [@terminal_turn_states, cutoff]
      )

    _activity_evidence = ActivityRetention.prune()

    _input_artifact_references =
      execute_count("""
      WITH candidates AS (
        SELECT reference.input_id, reference.artifact_id
        FROM ingress_input_artifact_references AS reference
        JOIN ingress_inbox_entries AS input ON input.id = reference.input_id
        WHERE input.operational_pruned_at IS NOT NULL
        ORDER BY reference.input_id, reference.artifact_id
        LIMIT 500
        FOR UPDATE OF reference SKIP LOCKED
      )
      DELETE FROM ingress_input_artifact_references AS reference
      USING candidates
      WHERE reference.input_id = candidates.input_id
        AND reference.artifact_id = candidates.artifact_id
      """)

    _work_artifact_references =
      execute_count("""
      WITH candidates AS (
        SELECT reference.turn_id, reference.artifact_id
        FROM work_input_artifact_references AS reference
        JOIN episode_work_turns AS turn ON turn.id = reference.turn_id
        WHERE turn.operational_pruned_at IS NOT NULL
        ORDER BY reference.turn_id, reference.artifact_id
        LIMIT 500
        FOR UPDATE OF reference SKIP LOCKED
      )
      DELETE FROM work_input_artifact_references AS reference
      USING candidates
      WHERE reference.turn_id = candidates.turn_id
        AND reference.artifact_id = candidates.artifact_id
      """)

    output_artifacts =
      execute_count(
        """
        WITH candidates AS (
          SELECT artifact.id
          FROM work_output_artifacts AS artifact
          JOIN episode_work_turns AS turn ON turn.id = artifact.turn_id
          WHERE turn.operational_pruned_at IS NOT NULL
            AND artifact.updated_at < clock_timestamp() - ($1 * interval '1 second')
          ORDER BY artifact.updated_at, artifact.id
          LIMIT 100
          FOR UPDATE OF artifact SKIP LOCKED
        )
        DELETE FROM work_output_artifacts AS artifact
        USING candidates
        WHERE artifact.id = candidates.id
        """,
        [cutoff]
      )

    input_artifacts =
      execute_count(
        """
        WITH candidates AS (
          SELECT artifact.id
          FROM input_artifacts AS artifact
          WHERE artifact.updated_at < clock_timestamp() - ($1 * interval '1 second')
            AND NOT EXISTS (
              SELECT 1 FROM ingress_input_artifact_references AS reference
              WHERE reference.artifact_id = artifact.id
            )
            AND NOT EXISTS (
              SELECT 1 FROM work_input_artifact_references AS reference
              WHERE reference.artifact_id = artifact.id
            )
          ORDER BY artifact.updated_at, artifact.id
          LIMIT 100
          FOR UPDATE OF artifact SKIP LOCKED
        )
        DELETE FROM input_artifacts AS artifact
        USING candidates
        WHERE artifact.id = candidates.id
        """,
        [cutoff]
      )

    %{
      result
      | configuration_sessions: configuration_sessions,
        conversation_memory: result.conversation_memory + learning_artifacts,
        delivery_reactions: reactions,
        input_artifacts: input_artifacts,
        operational_inputs: operational_inputs,
        operational_turns: operational_turns,
        output_artifacts: output_artifacts,
        worker_commands: worker_commands,
        worker_events: worker_events
    }
  end

  defp prune_closed_work(result, settings) do
    episode_predicate = terminal_episode_predicate("episode")
    cutoff = settings.closed_work_seconds

    room_events =
      execute_count(
        """
        WITH candidates AS (
          SELECT event.id
          FROM slack_incident_room_lifecycle_events AS event
          JOIN slack_incident_rooms AS room ON room.id = event.room_id
          JOIN episode_kernel_episodes AS episode
            ON episode.id = COALESCE(room.episode_id, room.source_episode_id)
          WHERE room.status = 'closed'
            AND room.updated_at < clock_timestamp() - ($1 * interval '1 second')
            AND #{episode_predicate}
            AND NOT EXISTS (
              SELECT 1 FROM episode_work_sessions session
              WHERE session.episode_id = episode.id AND session.cleanup_status <> 'discarded'
            )
          ORDER BY event.inserted_at, event.id
          LIMIT 100
          FOR UPDATE OF event SKIP LOCKED
        )
        DELETE FROM slack_incident_room_lifecycle_events AS event
        USING candidates
        WHERE event.id = candidates.id
        """,
        [cutoff]
      )

    rooms =
      execute_count(
        """
        WITH candidates AS (
          SELECT room.id
          FROM slack_incident_rooms AS room
          JOIN episode_kernel_episodes AS episode
            ON episode.id = COALESCE(room.episode_id, room.source_episode_id)
          WHERE room.status = 'closed'
            AND room.updated_at < clock_timestamp() - ($1 * interval '1 second')
            AND #{episode_predicate}
            AND NOT EXISTS (
              SELECT 1 FROM episode_work_sessions session
              WHERE session.episode_id = episode.id AND session.cleanup_status <> 'discarded'
            )
          ORDER BY room.updated_at, room.id
          LIMIT 100
          FOR UPDATE OF room SKIP LOCKED
        )
        DELETE FROM slack_incident_rooms AS room
        USING candidates
        WHERE room.id = candidates.id
        """,
        [cutoff]
      )

    cards =
      execute_count(
        """
        WITH candidates AS (
          SELECT card.id
          FROM slack_task_cards AS card
          JOIN episode_kernel_episodes AS episode ON episode.id = card.episode_id
          WHERE card.updated_at < clock_timestamp() - ($1 * interval '1 second')
            AND #{episode_predicate}
            AND NOT EXISTS (
              SELECT 1 FROM episode_work_sessions session
              WHERE session.episode_id = episode.id AND session.cleanup_status <> 'discarded'
            )
          ORDER BY card.updated_at, card.id
          LIMIT 100
          FOR UPDATE OF card SKIP LOCKED
        )
        DELETE FROM slack_task_cards AS card
        USING candidates
        WHERE card.id = candidates.id
        """,
        [cutoff]
      )

    %{result | closed_work: room_events + rooms + cards}
  end

  defp prune_history(result, settings) do
    missed_schedule_runs =
      execute_count(
        """
        WITH candidates AS (
          SELECT id
          FROM episode_schedule_occurrences
          WHERE status = 'missed'
            AND updated_at < clock_timestamp() - ($1 * interval '1 second')
          ORDER BY updated_at, id
          LIMIT 100
          FOR UPDATE SKIP LOCKED
        )
        DELETE FROM episode_schedule_occurrences AS occurrence
        USING candidates
        WHERE occurrence.id = candidates.id
        """,
        [settings.episode_history_seconds]
      )

    standing_runs =
      execute_count(
        """
        WITH candidates AS (
          SELECT id
          FROM standing_assignment_runs
          WHERE outcome = ANY($1)
            AND inserted_at < clock_timestamp() - ($2 * interval '1 second')
          ORDER BY inserted_at, id
          LIMIT 100
          FOR UPDATE SKIP LOCKED
        )
        DELETE FROM standing_assignment_runs AS run
        USING candidates
        WHERE run.id = candidates.id
        """,
        [~w(decided superseded), settings.episode_history_seconds]
      )

    ids = history_candidates(settings.episode_history_seconds)
    dispatched_schedule_runs = prune_history_ids(ids)

    %{
      result
      | episode_histories: length(ids),
        schedule_runs: missed_schedule_runs + dispatched_schedule_runs,
        standing_runs: standing_runs
    }
  end

  defp history_candidates(horizon) do
    query = """
    SELECT episode.id::text
    FROM episode_kernel_episodes AS episode
    WHERE episode.state = ANY($1)
      AND episode.history_pruned_at IS NULL
      AND episode.updated_at < clock_timestamp() - ($2 * interval '1 second')
      AND NOT EXISTS (
        SELECT 1 FROM episode_work_sessions session
        WHERE session.episode_id = episode.id AND session.cleanup_status <> 'discarded'
      )
      AND NOT EXISTS (
        SELECT 1 FROM episode_work_turns turn
        WHERE turn.episode_id = episode.id AND turn.status <> ALL($3)
      )
      AND NOT EXISTS (
        SELECT 1 FROM episode_state_records record
        WHERE record.episode_id = episode.id
          AND (
            (record.status = 'open' AND record.kind NOT IN
              ('evidence', 'coverage', 'finding', 'progress', 'goal_state', 'alert_assessment'))
            OR record.updated_at >= clock_timestamp() - ($2 * interval '1 second')
          )
      )
      AND NOT EXISTS (
        SELECT 1 FROM episode_state_records record
        WHERE record.confirmed_episode_id = episode.id AND record.episode_id <> episode.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM operational_memory_entries memory
        JOIN episode_state_records record ON record.id = memory.offer_record_id
        WHERE record.episode_id = episode.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM operator_behaviors behavior
        JOIN episode_state_records record ON record.id = behavior.offer_record_id
        WHERE record.episode_id = episode.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM episode_schedules schedule
        WHERE schedule.source_episode_id = episode.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM episode_publications publication
        WHERE publication.episode_id = episode.id
          AND (
            publication.status <> 'published'
            OR publication.updated_at >= clock_timestamp() - ($2 * interval '1 second')
          )
      )
      AND NOT EXISTS (
        SELECT 1 FROM episode_publication_followups followup
        WHERE followup.episode_id = episode.id
          AND (
            followup.pr_state = 'open'
            OR followup.updated_at >= clock_timestamp() - ($2 * interval '1 second')
          )
      )
      AND NOT EXISTS (
        SELECT 1 FROM episode_publication_lifecycle_events event
        WHERE event.episode_id = episode.id
          AND (
            event.delivery_state <> 'delivered'
            OR event.wakeup_state = 'pending'
            OR event.updated_at >= clock_timestamp() - ($2 * interval '1 second')
          )
      )
      AND NOT EXISTS (
        SELECT 1 FROM episode_emisar_approvals approval
        WHERE approval.episode_id = episode.id
          AND (
            approval.status <> 'resumed'
            OR approval.updated_at >= clock_timestamp() - ($2 * interval '1 second')
          )
      )
      AND NOT EXISTS (
        SELECT 1 FROM slack_incident_rooms room
        WHERE (room.source_episode_id = episode.id OR room.episode_id = episode.id)
      )
      AND NOT EXISTS (
        SELECT 1 FROM slack_task_cards card
        WHERE card.episode_id = episode.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM standing_assignment_runs run
        WHERE run.episode_id = episode.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM ingress_inbox_entries input
        JOIN delivery_reactions reaction ON reaction.input_id = input.id
        WHERE input.episode_id = episode.id AND reaction.status <> 'delivered'
      )
      AND NOT EXISTS (
        SELECT 1 FROM platform_actions action
        WHERE action.episode_id = episode.id AND action.status <> 'delivered'
      )
      AND NOT EXISTS (
        SELECT 1 FROM episode_kernel_episodes child
        WHERE child.linked_episode_id = episode.id AND child.history_pruned_at IS NULL
      )
    ORDER BY episode.updated_at, episode.id
    LIMIT 10
    FOR UPDATE OF episode SKIP LOCKED
    """

    Repo.query!(query, [
      @terminal_episode_states,
      horizon,
      @terminal_turn_states
    ])
    |> Map.fetch!(:rows)
    |> List.flatten()
  end

  defp prune_history_ids([]), do: 0

  defp prune_history_ids(ids) do
    params = [ids]

    schedule_runs =
      execute_count(
        "DELETE FROM episode_schedule_occurrences WHERE child_episode_id IN (SELECT unnest($1::text[])::uuid)",
        params
      )

    execute_count(
      """
      DELETE FROM episode_publications
      WHERE episode_id IN (SELECT unnest($1::text[])::uuid)
        AND status = 'published'
      """,
      params
    )

    execute_count(
      "DELETE FROM episode_emisar_approvals WHERE episode_id IN (SELECT unnest($1::text[])::uuid) AND status = 'resumed'",
      params
    )

    execute_count(
      "DELETE FROM slack_task_cards WHERE episode_id IN (SELECT unnest($1::text[])::uuid)",
      params
    )

    execute_count(
      "DELETE FROM episode_state_record_responses WHERE record_id IN (SELECT id FROM episode_state_records WHERE episode_id IN (SELECT unnest($1::text[])::uuid))",
      params
    )

    execute_count(
      "DELETE FROM episode_event_subscriptions WHERE episode_id IN (SELECT unnest($1::text[])::uuid) AND status <> 'active'",
      params
    )

    execute_count(
      "DELETE FROM platform_actions WHERE episode_id IN (SELECT unnest($1::text[])::uuid) AND status = 'delivered'",
      params
    )

    execute_count(
      "DELETE FROM episode_work_activity WHERE episode_id IN (SELECT unnest($1::text[])::uuid)",
      params
    )

    execute_count(
      """
      DELETE FROM episode_state_records
      WHERE episode_id IN (SELECT unnest($1::text[])::uuid)
        AND (status <> 'open' OR kind IN
          ('evidence', 'coverage', 'finding', 'progress', 'goal_state', 'alert_assessment'))
      """,
      params
    )

    execute_count(
      "DELETE FROM episode_kernel_events WHERE episode_id IN (SELECT unnest($1::text[])::uuid)",
      params
    )

    execute_count(
      """
      UPDATE episode_kernel_episodes
      SET history_pruned_at = clock_timestamp(),
          input_revisions = '{}',
          linked_episode_id = NULL
      WHERE id IN (SELECT unnest($1::text[])::uuid)
      """,
      params
    )

    schedule_runs
  end

  defp prune_audit(result, settings) do
    cutover_items =
      execute_count(
        """
        WITH candidates AS (
          SELECT item.id
          FROM responder_cutover_items AS item
          JOIN responder_cutover_runs AS run ON run.id = item.run_id
          WHERE item.status IN ('applied', 'skipped', 'rolled_back', 'failed')
            AND run.status IN ('applied', 'rolled_back', 'failed')
            AND item.data::jsonb <> '{"retention":"pruned"}'::jsonb
            AND COALESCE(run.rolled_back_at, run.applied_at, run.updated_at)
                < clock_timestamp() - ($1 * interval '1 second')
          ORDER BY item.updated_at, item.id
          LIMIT 100
          FOR UPDATE OF item SKIP LOCKED
        )
        UPDATE responder_cutover_items AS item
        SET data = '{"retention":"pruned"}',
            updated_at = clock_timestamp()
        FROM candidates
        WHERE item.id = candidates.id
        """,
        [settings.audit_data_seconds]
      )

    worker_certificates =
      execute_count(
        """
        WITH candidates AS (
          SELECT certificate.sha256
          FROM coop_worker_certificates AS certificate
          JOIN coop_workers AS worker ON worker.id = certificate.worker_id
          WHERE certificate.expires_at < clock_timestamp() - ($1 * interval '1 second')
            AND certificate.sha256 <> worker.certificate_sha256
          ORDER BY certificate.expires_at, certificate.sha256
          LIMIT 100
          FOR UPDATE OF certificate SKIP LOCKED
        )
        DELETE FROM coop_worker_certificates AS certificate
        USING candidates
        WHERE certificate.sha256 = candidates.sha256
        """,
        [settings.audit_data_seconds]
      )

    audit_rows =
      execute_count(
        """
        WITH candidates AS (
          SELECT id FROM model_instruction_edits
          WHERE inserted_at < clock_timestamp() - ($1 * interval '1 second')
          ORDER BY inserted_at, id LIMIT 100 FOR UPDATE SKIP LOCKED
        )
        DELETE FROM model_instruction_edits AS edit
        USING candidates WHERE edit.id = candidates.id
        """,
        [settings.audit_data_seconds]
      ) +
        execute_count(
          """
          WITH candidates AS (
            SELECT id FROM slack_channel_setting_audit
            WHERE inserted_at < clock_timestamp() - ($1 * interval '1 second')
            ORDER BY inserted_at, id LIMIT 100 FOR UPDATE SKIP LOCKED
          )
          DELETE FROM slack_channel_setting_audit AS audit
          USING candidates WHERE audit.id = candidates.id
          """,
          [settings.audit_data_seconds]
        ) +
        execute_count(
          """
          WITH candidates AS (
            SELECT id FROM slack_interaction_audit
            WHERE repaint_status IN ('none', 'settled', 'blocked')
              AND inserted_at < clock_timestamp() - ($1 * interval '1 second')
            ORDER BY inserted_at, id LIMIT 100 FOR UPDATE SKIP LOCKED
          )
          DELETE FROM slack_interaction_audit AS audit
          USING candidates WHERE audit.id = candidates.id
          """,
          [settings.audit_data_seconds]
        ) +
        execute_count(
          """
          WITH candidates AS (
            SELECT id FROM slack_channel_membership_events
            WHERE inserted_at < clock_timestamp() - ($1 * interval '1 second')
            ORDER BY inserted_at, id LIMIT 100 FOR UPDATE SKIP LOCKED
          )
          DELETE FROM slack_channel_membership_events AS event
          USING candidates WHERE event.id = candidates.id
          """,
          [settings.audit_data_seconds]
        ) +
        execute_count(
          """
          WITH candidates AS (
            SELECT id FROM responder_operator_actions
            WHERE inserted_at < clock_timestamp() - ($1 * interval '1 second')
            ORDER BY inserted_at, id LIMIT 100 FOR UPDATE SKIP LOCKED
          )
          DELETE FROM responder_operator_actions AS action
          USING candidates WHERE action.id = candidates.id
          """,
          [settings.audit_data_seconds]
        ) +
        execute_count(
          """
          WITH candidates AS (
            SELECT id FROM retention_operator_actions
            WHERE inserted_at < clock_timestamp() - ($1 * interval '1 second')
            ORDER BY inserted_at, id LIMIT 100 FOR UPDATE SKIP LOCKED
          )
          DELETE FROM retention_operator_actions AS action
          USING candidates WHERE action.id = candidates.id
          """,
          [settings.audit_data_seconds]
        ) +
        execute_count(
          """
          WITH candidates AS (
            SELECT id FROM memory_review_items
            WHERE status <> 'pending'
              AND updated_at < clock_timestamp() - ($1 * interval '1 second')
            ORDER BY updated_at, id LIMIT 100 FOR UPDATE SKIP LOCKED
          )
          DELETE FROM memory_review_items AS review
          USING candidates WHERE review.id = candidates.id
          """,
          [settings.audit_data_seconds]
        )

    ids = audit_candidates(settings.audit_data_seconds)
    prune_audit_ids(ids)

    orphan_inputs =
      execute_count(
        """
        WITH candidates AS (
          SELECT input.id
          FROM ingress_inbox_entries AS input
          WHERE input.episode_id IS NULL
            AND input.operational_pruned_at IS NOT NULL
            AND input.updated_at < clock_timestamp() - ($1 * interval '1 second')
            AND NOT EXISTS (SELECT 1 FROM delivery_reactions reaction WHERE reaction.input_id = input.id)
            AND NOT EXISTS (SELECT 1 FROM episode_state_record_responses response WHERE response.inbox_entry_id = input.id)
          ORDER BY input.updated_at, input.id
          LIMIT 100
          FOR UPDATE OF input SKIP LOCKED
        )
        DELETE FROM ingress_inbox_entries AS input
        USING candidates
        WHERE input.id = candidates.id
        """,
        [settings.audit_data_seconds]
      )

    %{
      result
      | audit_episodes: length(ids),
        audit_rows: audit_rows + orphan_inputs + worker_certificates,
        cutover_items: cutover_items
    }
  end

  defp audit_candidates(horizon) do
    Repo.query!(
      """
      SELECT episode.id::text
      FROM episode_kernel_episodes AS episode
      WHERE episode.history_pruned_at IS NOT NULL
        AND episode.updated_at < clock_timestamp() - ($1 * interval '1 second')
        AND NOT EXISTS (
          SELECT 1 FROM episode_kernel_episodes child WHERE child.linked_episode_id = episode.id
        )
        AND NOT EXISTS (
          SELECT 1 FROM episode_state_records record WHERE record.confirmed_episode_id = episode.id
        )
        AND NOT EXISTS (
          SELECT 1 FROM episode_work_sessions session
          WHERE session.episode_id = episode.id AND session.cleanup_status <> 'discarded'
        )
        AND NOT EXISTS (
          SELECT 1 FROM platform_actions action
          WHERE action.episode_id = episode.id AND action.status <> 'delivered'
        )
      ORDER BY episode.updated_at, episode.id
      LIMIT 10
      """,
      [horizon]
    )
    |> Map.fetch!(:rows)
    |> List.flatten()
  end

  defp prune_audit_ids([]), do: :ok

  defp prune_audit_ids(ids) do
    params = [ids]

    execute_count(
      "DELETE FROM episode_operator_reviews WHERE episode_id IN (SELECT unnest($1::text[])::uuid)",
      params
    )

    execute_count(
      "DELETE FROM episode_work_activity WHERE episode_id IN (SELECT unnest($1::text[])::uuid)",
      params
    )

    execute_count(
      "DELETE FROM coop_worker_events WHERE session_id IN (SELECT id FROM episode_work_sessions WHERE episode_id IN (SELECT unnest($1::text[])::uuid))",
      params
    )

    execute_count(
      "DELETE FROM coop_worker_commands WHERE session_id IN (SELECT id FROM episode_work_sessions WHERE episode_id IN (SELECT unnest($1::text[])::uuid))",
      params
    )

    execute_count(
      "DELETE FROM coop_session_placements WHERE session_id IN (SELECT id FROM episode_work_sessions WHERE episode_id IN (SELECT unnest($1::text[])::uuid))",
      params
    )

    execute_count(
      "DELETE FROM retention_operator_actions WHERE session_id IN (SELECT id FROM episode_work_sessions WHERE episode_id IN (SELECT unnest($1::text[])::uuid))",
      params
    )

    execute_count(
      "DELETE FROM delivery_reactions WHERE input_id IN (SELECT id FROM ingress_inbox_entries WHERE episode_id IN (SELECT unnest($1::text[])::uuid)) AND status = 'delivered'",
      params
    )

    execute_count(
      "DELETE FROM ingress_inbox_entries WHERE episode_id IN (SELECT unnest($1::text[])::uuid)",
      params
    )

    execute_count(
      "DELETE FROM platform_actions WHERE episode_id IN (SELECT unnest($1::text[])::uuid) AND status = 'delivered'",
      params
    )

    execute_count(
      "DELETE FROM episode_work_turns WHERE episode_id IN (SELECT unnest($1::text[])::uuid) AND status = ANY($2)",
      [ids, @terminal_turn_states]
    )

    execute_count(
      "DELETE FROM episode_work_sessions WHERE episode_id IN (SELECT unnest($1::text[])::uuid) AND cleanup_status = 'discarded'",
      params
    )

    execute_count(
      "DELETE FROM episode_kernel_episodes WHERE id IN (SELECT unnest($1::text[])::uuid) AND history_pruned_at IS NOT NULL",
      params
    )

    :ok
  end

  defp advisory_lock? do
    %{rows: [[locked]]} = Repo.query!("SELECT pg_try_advisory_lock($1)", [@advisory_lock])
    locked
  end

  defp release_advisory_lock! do
    %{rows: [[true]]} = Repo.query!("SELECT pg_advisory_unlock($1)", [@advisory_lock])
    :ok
  end

  defp terminal_episode_predicate(alias_name) do
    "#{alias_name}.state IN ('complete', 'cancelled')"
  end

  defp execute_count(sql, params \\ []) do
    sql
    |> Repo.query!(params)
    |> Map.fetch!(:num_rows)
  end

  defp empty_result do
    %{
      audit_episodes: 0,
      audit_rows: 0,
      closed_work: 0,
      configuration_sessions: 0,
      conversation_memory: 0,
      cutover_items: 0,
      delivery_reactions: 0,
      episode_histories: 0,
      input_artifacts: 0,
      operational_inputs: 0,
      operational_turns: 0,
      output_artifacts: 0,
      schedule_runs: 0,
      standing_runs: 0,
      worker_commands: 0,
      worker_events: 0
    }
  end

  defp settings(settings) when is_list(settings) do
    if Keyword.keyword?(settings) and Enum.uniq(Keyword.keys(settings)) == Keyword.keys(settings),
      do: settings |> Map.new() |> settings(),
      else: {:error, {:invalid_retention_data, :settings}}
  end

  defp settings(%{} = settings) do
    required =
      ~w(audit_data_seconds closed_work_seconds conversation_memory_seconds episode_history_seconds operational_data_seconds)a

    valid =
      Map.keys(settings) |> Enum.sort() == Enum.sort(required) and
        Enum.all?(required, &(is_integer(settings[&1]) and settings[&1] > 0)) and
        settings.operational_data_seconds <= settings.closed_work_seconds and
        settings.closed_work_seconds <= settings.episode_history_seconds and
        settings.episode_history_seconds <= settings.audit_data_seconds and
        settings.operational_data_seconds <= settings.conversation_memory_seconds

    if valid, do: {:ok, settings}, else: {:error, {:invalid_retention_data, :settings}}
  end

  defp settings(_settings), do: {:error, {:invalid_retention_data, :settings}}
end
