defmodule Ryker.Retention.Data do
  @moduledoc """
  Ownership-aware PostgreSQL data pruning.

  Operational payloads are redacted only after every Coop session owned by an
  episode is proven discarded. Episode history is removed as one coherent
  unit, never event-by-event, and compact custody receipts survive until the
  audit horizon. Every age comparison uses PostgreSQL time.
  """

  alias Ryker.Continuity.Compaction
  alias Ryker.Knowledge.KnowledgeRetention
  alias Ryker.Learning
  alias Ryker.Memories.Cases
  alias Ryker.Memories.Reviews
  alias Ryker.Repo
  alias Ryker.Work.ActivityRetention

  @advisory_lock 7_152_019_552_843_111
  @terminal_episode_states ~w(complete cancelled)
  @terminal_turn_states ~w(settled superseded)
  @summary_compaction_seconds 7 * 86_400
  @memory_review_seconds 30 * 86_400

  @type result :: %{
          audit_episodes: non_neg_integer(),
          audit_rows: non_neg_integer(),
          closed_work: non_neg_integer(),
          configuration_sessions: non_neg_integer(),
          conversation_memory: non_neg_integer(),
          routing_responses: non_neg_integer(),
          episode_histories: non_neg_integer(),
          input_artifacts: non_neg_integer(),
          operational_inputs: non_neg_integer(),
          operational_turns: non_neg_integer(),
          output_artifacts: non_neg_integer(),
          rule_inventories: non_neg_integer(),
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

  # Most tables expire in one shape, so their rules are data run by
  # prune_aged/2: a batch of at most `limit` rows (100 unless given) that match
  # `where` and whose `age` column is older than the `horizon` setting, taken
  # oldest first, locked with SKIP LOCKED so a row another transaction holds is
  # never waited on, and deleted by id. `where` and `join` name the table by
  # `as`, or by its own name when there is no `as`; the horizon is `$1`.
  # Statements that differ from that shape are written out, each saying why.

  # Expiring resources: bounded memory, summaries and finished schedules.

  # A global, active fact has no age limit and leaves only at its own expiry,
  # so the horizon is one branch of an OR instead of a condition every row
  # meets.
  @prune_operational_memory """
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
  """

  @settled_summary_drafts %{
    table: "conversation_summary_drafts",
    as: "draft",
    join: "JOIN episode_work_turns AS turn ON turn.id = draft.turn_id",
    where: "turn.status IN ('settled', 'superseded')",
    age: "updated_at",
    horizon: :operational_data_seconds
  }

  @finished_schedules %{
    table: "episode_schedules",
    where: """
    status IN ('completed', 'expired', 'deleted')
      AND NOT EXISTS (
        SELECT 1
        FROM episode_schedule_occurrences AS occurrence
        WHERE occurrence.schedule_id = episode_schedules.id
      )
    """,
    age: "updated_at",
    horizon: :episode_history_seconds
  }

  # A note is cleared, not deleted: the observation's revision receipt stays.
  @clear_observation_notes """
  WITH candidates AS (
    SELECT id FROM conversation_observations
    WHERE note IS NOT NULL
      AND updated_at < clock_timestamp() - ($1 * interval '1 second')
    ORDER BY updated_at, id LIMIT 100 FOR UPDATE SKIP LOCKED
  )
  UPDATE conversation_observations AS note SET note = NULL FROM candidates
  WHERE note.id = candidates.id
  """

  defp prune_expiring_resources(result, settings) do
    memory_seconds = settings.conversation_memory_seconds

    {:ok, _reviews_created} =
      Reviews.refresh_all_reviews_in_transaction(min(memory_seconds, @memory_review_seconds))

    {:ok, compacted} =
      Compaction.compact_in_transaction(
        min(memory_seconds, @summary_compaction_seconds),
        memory_seconds
      )

    memory = execute_count(@prune_operational_memory, [memory_seconds])
    rollups = prune_expired("conversation_rollups")
    _drafts = prune_aged(@settled_summary_drafts, settings)
    _behaviors = prune_expired("operator_behaviors")
    :ok = Reviews.dismiss_invalid_reviews_in_transaction()
    _schedules = prune_aged(@finished_schedules, settings)
    observations = execute_count(@clear_observation_notes, [memory_seconds])
    knowledge = KnowledgeRetention.prune_in_transaction(memory_seconds)

    %{result | conversation_memory: memory + compacted + rollups + observations + knowledge}
  end

  # Operational bodies: transport, worker journals, inputs, turns and artifacts.

  @delivered_statuses %{
    table: "slack_thread_statuses",
    where: "status = 'delivered' AND desired_text = ''",
    age: "updated_at",
    horizon: :operational_data_seconds
  }

  @spent_enrollment_tokens %{
    table: "coop_worker_enrollment_tokens",
    where: "consumed_at IS NOT NULL OR expires_at <= clock_timestamp()",
    age: "inserted_at",
    horizon: :operational_data_seconds
  }

  @finished_worker_commands %{
    table: "coop_worker_commands",
    as: "command",
    join: "JOIN episode_work_sessions AS session ON session.id = command.session_id",
    where: """
    command.status IN ('succeeded', 'failed') AND session.cleanup_status = 'discarded'
    AND NOT EXISTS (
      SELECT 1 FROM coop_worker_workspace_checkpoints AS checkpoint
      WHERE checkpoint.body_command_id = command.id
    )
    """,
    age: "updated_at",
    horizon: :operational_data_seconds
  }

  @discarded_worker_events %{
    table: "coop_worker_events",
    as: "event",
    join: "JOIN episode_work_sessions AS session ON session.id = event.session_id",
    where: "session.cleanup_status = 'discarded'",
    age: "inserted_at",
    horizon: :operational_data_seconds
  }

  # An operator decision (rearm, unmerged discard) names its session and is
  # audit-class, so the session row stays until the audit prune has removed
  # the decision. Without this guard, one learning session rearmed from App
  # Home made this DELETE raise on every pass after its discard, which
  # aborted this phase and every later one for good.
  #
  # Written out because the session leaves with its activity and placement
  # rows in one statement, and only once nothing else names it.
  @prune_non_work_sessions """
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
      AND NOT EXISTS (
        SELECT 1 FROM retention_operator_actions action
        WHERE action.session_id = session.id
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
  """

  # A delivery is kept for de-duplication while GitHub may still redeliver it,
  # and a repository's newest one for connection health however old; one not
  # yet processed is still custody.
  @processed_github_events %{
    table: "github_repository_events",
    as: "event",
    where: """
    event.disposition <> 'received'
    AND EXISTS (
      SELECT 1 FROM github_repository_events AS newer
      WHERE newer.binding_ref = event.binding_ref
        AND (newer.occurred_at, newer.id) > (event.occurred_at, event.id)
    )
    """,
    age: "inserted_at",
    horizon: :operational_data_seconds
  }

  @delivered_routing_responses %{
    table: "delivery_routing_responses",
    where: "status = 'delivered'",
    age: "updated_at",
    horizon: :operational_data_seconds
  }

  # A finished setup conversation ages from its last change, and every one from
  # its own expiry, so the horizon applies to either branch of an OR.
  @prune_configuration_sessions """
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
  """

  # A learning batch that is leased, or whose run is still out at the model,
  # needs the exact bodies it was given; pruning them fenced the turn as
  # learning_source_stale and wasted the start. A queued batch retires a
  # pruned input on its own and keeps the rest.
  #
  # Written out because the bodies are redacted in place: the input row and
  # its custody stay.
  @prune_operational_inputs """
  WITH candidates AS (
    SELECT input.id
    FROM ingress_inbox_entries AS input
    WHERE input.operational_pruned_at IS NULL
      AND input.status = ANY($1)
      AND input.updated_at < clock_timestamp() - ($2 * interval '1 second')
      AND NOT EXISTS (
        SELECT 1 FROM delivery_routing_responses response
        WHERE response.input_id = input.id AND response.status <> 'delivered'
      )
      AND (
        input.episode_id IS NULL
        OR NOT EXISTS (
          SELECT 1 FROM episode_work_sessions session
          WHERE session.episode_id = input.episode_id
            AND session.cleanup_status <> 'discarded'
        )
      )
      AND NOT EXISTS (
        SELECT 1 FROM conversation_learning_inputs AS membership
        JOIN conversation_learning_batches AS batch ON batch.id = membership.batch_id
        WHERE membership.input_id = input.id
          AND (
            batch.status = 'running'
            OR EXISTS (
              SELECT 1 FROM conversation_learning_runs AS run
              WHERE run.batch_id = batch.id
                AND run.started_at IS NOT NULL AND run.remote_stopped_at IS NULL
            )
          )
      )
    ORDER BY input.updated_at, input.id
    LIMIT 100
    FOR UPDATE OF input SKIP LOCKED
  )
  UPDATE ingress_inbox_entries AS input
  SET content = '{"retention":"pruned"}',
      source_envelope = CASE WHEN source_envelope IS NULL THEN NULL ELSE '{"retention":"pruned"}' END,
      admission_context = NULL,
      admission_context_fingerprint = NULL,
      decision_document = '{"retention":"pruned"}',
      operational_pruned_at = clock_timestamp()
  FROM candidates
  WHERE input.id = candidates.id
  """

  # Written out because the classifier artifacts are redacted in place, and
  # as soon as their input's bodies are, with no horizon of their own.
  @prune_admission_artifacts """
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
  """

  # A receipt is the trace's evidence of what Slack acknowledged for its
  # episode (directly, or through one of the episode's inputs); it stays
  # while that episode is open.
  @finished_status_receipts %{
    table: "slack_thread_status_receipts",
    as: "receipt",
    where: """
    NOT EXISTS (
      SELECT 1 FROM episode_kernel_episodes AS episode
      WHERE episode.state NOT IN ('complete', 'cancelled')
        AND episode.id = CASE receipt.origin_kind
          WHEN 'episode' THEN receipt.origin_id
          WHEN 'input' THEN (
            SELECT input.episode_id FROM ingress_inbox_entries AS input
            WHERE input.id = receipt.origin_id
          )
        END
    )
    """,
    age: "inserted_at",
    horizon: :operational_data_seconds,
    limit: 1000
  }

  # Written out because the turn's bodies and its candidate response bodies
  # are redacted in place; the turn stays as history.
  @prune_operational_turns """
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
  """

  # The two artifact reference tables are written out because a reference is
  # keyed by its owner and its artifact, not by an id, and goes as soon as its
  # owner's bodies are pruned, with no horizon of its own.
  @prune_input_artifact_references """
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
  """

  @prune_work_artifact_references """
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
  """

  # Written out because a recorded call has no age of its own: it goes as soon
  # as its turn's bodies are pruned, taken in turn order.
  @prune_state_tool_calls """
  WITH candidates AS (
    SELECT call.id
    FROM episode_work_state_tool_calls AS call
    JOIN episode_work_turns AS turn ON turn.id = call.turn_id
    WHERE turn.operational_pruned_at IS NOT NULL
    ORDER BY call.turn_id, call.id
    LIMIT 1000
    FOR UPDATE OF call SKIP LOCKED
  )
  DELETE FROM episode_work_state_tool_calls AS call
  USING candidates
  WHERE call.id = candidates.id
  """

  @pruned_turn_outputs %{
    table: "work_output_artifacts",
    as: "artifact",
    join: "JOIN episode_work_turns AS turn ON turn.id = artifact.turn_id",
    where: "turn.operational_pruned_at IS NOT NULL",
    age: "updated_at",
    horizon: :operational_data_seconds
  }

  @unreferenced_input_artifacts %{
    table: "input_artifacts",
    as: "artifact",
    where: """
    NOT EXISTS (
      SELECT 1 FROM ingress_input_artifact_references AS reference
      WHERE reference.artifact_id = artifact.id
    )
    AND NOT EXISTS (
      SELECT 1 FROM work_input_artifact_references AS reference
      WHERE reference.artifact_id = artifact.id
    )
    """,
    age: "updated_at",
    horizon: :operational_data_seconds
  }

  defp prune_operational(result, settings) do
    cutoff = settings.operational_data_seconds

    _slack_thread_statuses = prune_aged(@delivered_statuses, settings)
    _worker_enrollment_tokens = prune_aged(@spent_enrollment_tokens, settings)
    worker_commands = prune_aged(@finished_worker_commands, settings)
    worker_events = prune_aged(@discarded_worker_events, settings)
    _non_work_sessions = execute_count(@prune_non_work_sessions, [cutoff])
    routing_responses = prune_aged(@delivered_routing_responses, settings)
    _github_events = prune_aged(@processed_github_events, settings)

    configuration_sessions =
      execute_count(@prune_configuration_sessions, [~w(saved cancelled expired), cutoff])

    operational_inputs =
      execute_count(@prune_operational_inputs, [~w(decided superseded), cutoff])

    learning_artifacts = Learning.prune_in_transaction(settings.conversation_memory_seconds)
    _admission_artifacts = execute_count(@prune_admission_artifacts)
    _status_receipts = prune_aged(@finished_status_receipts, settings)
    operational_turns = execute_count(@prune_operational_turns, [@terminal_turn_states, cutoff])
    _activity_evidence = ActivityRetention.prune()
    _input_artifact_references = execute_count(@prune_input_artifact_references)
    _work_artifact_references = execute_count(@prune_work_artifact_references)
    _state_tool_calls = execute_count(@prune_state_tool_calls)
    output_artifacts = prune_aged(@pruned_turn_outputs, settings)
    input_artifacts = prune_aged(@unreferenced_input_artifacts, settings)

    %{
      result
      | configuration_sessions: configuration_sessions,
        conversation_memory: result.conversation_memory + learning_artifacts,
        routing_responses: routing_responses,
        input_artifacts: input_artifacts,
        operational_inputs: operational_inputs,
        operational_turns: operational_turns,
        output_artifacts: output_artifacts,
        worker_commands: worker_commands,
        worker_events: worker_events
    }
  end

  # Closed work: incident rooms and task cards.

  # A room is owned by the thread episode that offered it and by the incident
  # episode that ran in it; both must be finished, like the history pin.
  @room_owners_finished """
  NOT EXISTS (
    SELECT 1 FROM episode_kernel_episodes AS owner
    WHERE owner.id IN (room.source_episode_id, room.episode_id)
      AND (
        NOT owner.state IN ('complete', 'cancelled')
        OR EXISTS (
          SELECT 1 FROM episode_work_sessions session
          WHERE session.episode_id = owner.id AND session.cleanup_status <> 'discarded'
        )
      )
  )
  """

  # Written out because a lifecycle event ages with its room, not by its own
  # time, and is taken in the order it happened.
  @prune_room_events """
  WITH candidates AS (
    SELECT event.id
    FROM slack_incident_room_lifecycle_events AS event
    JOIN slack_incident_rooms AS room ON room.id = event.room_id
    WHERE room.status = 'closed'
      AND room.updated_at < clock_timestamp() - ($1 * interval '1 second')
      AND #{@room_owners_finished}
    ORDER BY event.inserted_at, event.id
    LIMIT 100
    FOR UPDATE OF event SKIP LOCKED
  )
  DELETE FROM slack_incident_room_lifecycle_events AS event
  USING candidates
  WHERE event.id = candidates.id
  """

  @closed_rooms %{
    table: "slack_incident_rooms",
    as: "room",
    where: "room.status = 'closed' AND #{@room_owners_finished}",
    age: "updated_at",
    horizon: :closed_work_seconds
  }

  @finished_task_cards %{
    table: "slack_task_cards",
    as: "card",
    join: "JOIN episode_kernel_episodes AS episode ON episode.id = card.episode_id",
    where: """
    episode.state IN ('complete', 'cancelled')
      AND NOT EXISTS (
        SELECT 1 FROM episode_work_sessions session
        WHERE session.episode_id = episode.id AND session.cleanup_status <> 'discarded'
      )
    """,
    age: "updated_at",
    horizon: :closed_work_seconds
  }

  defp prune_closed_work(result, settings) do
    room_events = execute_count(@prune_room_events, [settings.closed_work_seconds])
    rooms = prune_aged(@closed_rooms, settings)
    cards = prune_aged(@finished_task_cards, settings)

    %{result | closed_work: room_events + rooms + cards}
  end

  # Episode history: schedule and standing runs, rule inventories, and whole
  # episodes whose history nothing still pins.

  @missed_schedule_runs %{
    table: "episode_schedule_occurrences",
    where: "status = 'missed'",
    age: "updated_at",
    horizon: :episode_history_seconds
  }

  @finished_standing_runs %{
    table: "standing_assignment_runs",
    where: """
    outcome IN ('decided', 'superseded')
      AND NOT EXISTS (
        SELECT 1 FROM episode_kernel_episodes AS episode
        WHERE episode.id = standing_assignment_runs.episode_id
          AND episode.state NOT IN ('complete', 'cancelled')
      )
    """,
    age: "inserted_at",
    horizon: :episode_history_seconds
  }

  # The inventory expires with its input's history: never while the episode
  # that input started or joined is still open.
  @finished_rule_inventories %{
    table: "standing_rule_inventories",
    as: "inventory",
    where: """
    NOT EXISTS (
      SELECT 1 FROM ingress_inbox_entries AS input
      JOIN episode_kernel_episodes AS episode ON episode.id = input.episode_id
      WHERE inventory.source_input_ref = 'ingress-input:' || input.id::text
        AND episode.state NOT IN ('complete', 'cancelled')
    )
    """,
    age: "recorded_at",
    horizon: :episode_history_seconds
  }

  # Written out because it chooses whole episodes, not rows: every NOT EXISTS
  # names something that still pins an episode's history.
  @history_candidates """
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
          approval.status NOT IN ('resumed', 'closed')
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
      JOIN delivery_routing_responses response ON response.input_id = input.id
      WHERE input.episode_id = episode.id AND response.status <> 'delivered'
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

  # The episode ids a candidate query chose, passed as `$1`, and the sessions
  # and inputs those episodes own.
  @episode_ids "(SELECT unnest($1::text[])::uuid)"
  @episode_sessions "(SELECT id FROM episode_work_sessions WHERE episode_id IN #{@episode_ids})"
  @episode_inputs "(SELECT id FROM ingress_inbox_entries WHERE episode_id IN #{@episode_ids})"

  # The history of each chosen episode, removed as one unit. The episode row,
  # its sessions, turns and inputs stay until the audit horizon.
  @history_rows [
    {"episode_publications", "episode_id IN #{@episode_ids} AND status = 'published'"},
    {"episode_emisar_approvals",
     "episode_id IN #{@episode_ids} AND status IN ('resumed', 'closed')"},
    {"slack_task_cards", "episode_id IN #{@episode_ids}"},
    {"episode_state_record_responses",
     "record_id IN (SELECT id FROM episode_state_records WHERE episode_id IN #{@episode_ids})"},
    {"episode_event_subscriptions", "episode_id IN #{@episode_ids} AND status <> 'active'"},
    {"platform_actions", "episode_id IN #{@episode_ids} AND status = 'delivered'"},
    {"episode_work_activity", "episode_id IN #{@episode_ids}"},
    {"coop_session_evidence", "episode_id IN #{@episode_ids}"},
    {"episode_state_records",
     "episode_id IN #{@episode_ids} AND (status <> 'open' OR kind IN ('evidence', 'coverage', 'finding', 'progress', 'goal_state', 'alert_assessment'))"},
    {"episode_routing_digests", "episode_id IN #{@episode_ids}"},
    {"episode_input_origins", "episode_id IN #{@episode_ids}"},
    {"episode_kernel_events", "episode_id IN #{@episode_ids}"}
  ]

  defp prune_history(result, settings) do
    missed_schedule_runs = prune_aged(@missed_schedule_runs, settings)
    standing_runs = prune_aged(@finished_standing_runs, settings)
    rule_inventories = prune_aged(@finished_rule_inventories, settings)
    ids = history_candidates(settings.episode_history_seconds)

    # The compact case is written before its raw episode is reclaimed, so a
    # pending lesson review is never the reason the useful part of an incident
    # disappears at the history horizon.
    _cases = Cases.capture_many(ids)

    dispatched_schedule_runs = prune_history_ids(ids)

    %{
      result
      | episode_histories: length(ids),
        rule_inventories: rule_inventories,
        schedule_runs: missed_schedule_runs + dispatched_schedule_runs,
        standing_runs: standing_runs
    }
  end

  defp history_candidates(horizon) do
    @history_candidates
    |> Repo.query!([@terminal_episode_states, horizon, @terminal_turn_states])
    |> Map.fetch!(:rows)
    |> List.flatten()
  end

  defp prune_history_ids([]), do: 0

  # The schedule firing that started a chosen episode is counted, so it goes
  # first and on its own; the episode row is marked, not deleted, so it goes
  # last.
  defp prune_history_ids(ids) do
    schedule_runs =
      execute_count(
        "DELETE FROM episode_schedule_occurrences WHERE child_episode_id IN #{@episode_ids}",
        [ids]
      )

    delete_owned(@history_rows, ids)

    execute_count(
      """
      UPDATE episode_kernel_episodes
      SET history_pruned_at = clock_timestamp(),
          input_revisions = '{}',
          linked_episode_id = NULL
      WHERE id IN #{@episode_ids}
      """,
      [ids]
    )

    schedule_runs
  end

  # Audit custody: ledgers, retired worker certificates, and the rows of
  # episodes whose history is already gone.

  # Written out because a certificate is keyed by its digest, not an id, and
  # the one its worker presents now is kept however old it is.
  @prune_retired_certificates """
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
  """

  # Audit ledgers are kept for the audit horizon and no longer.
  @audit_ledgers [
    %{table: "settings_edits", age: "inserted_at", horizon: :audit_data_seconds},
    %{table: "integration_credential_events", age: "inserted_at", horizon: :audit_data_seconds},
    %{table: "model_instruction_edits", age: "inserted_at", horizon: :audit_data_seconds},
    %{table: "settings_import_receipts", age: "inserted_at", horizon: :audit_data_seconds},
    %{table: "slack_channel_setting_audit", age: "inserted_at", horizon: :audit_data_seconds},
    %{
      table: "slack_interaction_audit",
      where: "repaint_status IN ('none', 'settled', 'blocked')",
      age: "inserted_at",
      horizon: :audit_data_seconds
    },
    %{table: "slack_channel_membership_events", age: "inserted_at", horizon: :audit_data_seconds},
    %{table: "ryker_operator_actions", age: "inserted_at", horizon: :audit_data_seconds},
    %{table: "retention_operator_actions", age: "inserted_at", horizon: :audit_data_seconds},
    %{
      table: "memory_review_items",
      where: "status <> 'pending'",
      age: "updated_at",
      horizon: :audit_data_seconds
    }
  ]

  @orphan_inputs %{
    table: "ingress_inbox_entries",
    as: "input",
    where: """
    input.episode_id IS NULL
      AND input.operational_pruned_at IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM delivery_routing_responses routed WHERE routed.input_id = input.id)
      AND NOT EXISTS (SELECT 1 FROM episode_state_record_responses response WHERE response.inbox_entry_id = input.id)
    """,
    age: "updated_at",
    horizon: :audit_data_seconds
  }

  # Written out because it chooses whole episodes, not rows.
  @audit_candidates """
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
  """

  # Everything else a chosen episode still owns, then the episode row itself.
  @audit_rows [
    {"episode_operator_reviews", "episode_id IN #{@episode_ids}"},
    {"episode_work_activity", "episode_id IN #{@episode_ids}"},
    {"coop_session_evidence", "session_id IN #{@episode_sessions}"},
    {"coop_worker_events", "session_id IN #{@episode_sessions}"},
    {"coop_worker_commands", "session_id IN #{@episode_sessions}"},
    {"coop_session_placements", "session_id IN #{@episode_sessions}"},
    {"retention_operator_actions", "session_id IN #{@episode_sessions}"},
    {"delivery_routing_responses", "input_id IN #{@episode_inputs} AND status = 'delivered'"},
    {"ingress_inbox_entries", "episode_id IN #{@episode_ids}"},
    {"platform_actions", "episode_id IN #{@episode_ids} AND status = 'delivered'"},
    {"episode_work_turns", "episode_id IN #{@episode_ids} AND status = ANY($2)",
     [@terminal_turn_states]},
    {"episode_work_sessions", "episode_id IN #{@episode_ids} AND cleanup_status = 'discarded'"},
    {"episode_kernel_episodes", "id IN #{@episode_ids} AND history_pruned_at IS NOT NULL"}
  ]

  defp prune_audit(result, settings) do
    worker_certificates =
      execute_count(@prune_retired_certificates, [settings.audit_data_seconds])

    audit_rows = @audit_ledgers |> Enum.map(&prune_aged(&1, settings)) |> Enum.sum()
    ids = audit_candidates(settings.audit_data_seconds)
    prune_audit_ids(ids)
    orphan_inputs = prune_aged(@orphan_inputs, settings)

    %{
      result
      | audit_episodes: length(ids),
        audit_rows: audit_rows + orphan_inputs + worker_certificates
    }
  end

  defp audit_candidates(horizon) do
    @audit_candidates
    |> Repo.query!([horizon])
    |> Map.fetch!(:rows)
    |> List.flatten()
  end

  defp prune_audit_ids([]), do: :ok
  defp prune_audit_ids(ids), do: delete_owned(@audit_rows, ids)

  # The shared shape described above the rules. Table and column names come
  # from the literals in this module, never from data.
  defp prune_aged(rule, settings) do
    table = rule.table
    name = Map.get(rule, :as, table)
    source = if name == table, do: table, else: "#{table} AS #{name}"
    older = "#{name}.#{rule.age} < clock_timestamp() - ($1 * interval '1 second')"

    condition =
      case Map.get(rule, :where) do
        nil -> older
        where -> "(#{where}) AND #{older}"
      end

    execute_count(
      """
      WITH candidates AS (
        SELECT #{name}.id
        FROM #{source} #{Map.get(rule, :join, "")}
        WHERE #{condition}
        ORDER BY #{name}.#{rule.age}, #{name}.id
        LIMIT #{Map.get(rule, :limit, 100)}
        FOR UPDATE OF #{name} SKIP LOCKED
      )
      DELETE FROM #{source}
      USING candidates
      WHERE #{name}.id = candidates.id
      """,
      [Map.fetch!(settings, rule.horizon)]
    )
  end

  # Rows that carry their own expiry go once it passes; no horizon applies.
  defp prune_expired(table) do
    execute_count("""
    WITH candidates AS (
      SELECT id
      FROM #{table}
      WHERE expires_at <= clock_timestamp()
      ORDER BY expires_at, id
      LIMIT 100
      FOR UPDATE SKIP LOCKED
    )
    DELETE FROM #{table} AS expired
    USING candidates
    WHERE expired.id = candidates.id
    """)
  end

  # Every row the chosen episodes still own, table by table in the order
  # listed: a row goes before the rows it references. `$1` is the episode ids;
  # an entry's own parameters follow it.
  defp delete_owned(statements, ids) do
    Enum.each(statements, fn
      {table, owned} ->
        execute_count("DELETE FROM #{table} WHERE #{owned}", [ids])

      {table, owned, params} ->
        execute_count("DELETE FROM #{table} WHERE #{owned}", [ids | params])
    end)
  end

  defp advisory_lock? do
    %{rows: [[locked]]} = Repo.query!("SELECT pg_try_advisory_lock($1)", [@advisory_lock])
    locked
  end

  defp release_advisory_lock! do
    %{rows: [[true]]} = Repo.query!("SELECT pg_advisory_unlock($1)", [@advisory_lock])
    :ok
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
      routing_responses: 0,
      episode_histories: 0,
      input_artifacts: 0,
      operational_inputs: 0,
      operational_turns: 0,
      output_artifacts: 0,
      rule_inventories: 0,
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
