defmodule Ryker.Retention.Data do
  @moduledoc """
  Ownership-aware PostgreSQL data pruning.

  Operational payloads are redacted only after every Coop session owned by an
  episode is proven discarded. Episode history is removed as one coherent
  unit, never event-by-event, and compact custody receipts survive until the
  audit horizon. Every age comparison uses PostgreSQL time.

  A pass that removed or redacted anything is announced once it has committed
  (`subscribe_pruning/0`).
  """
  alias Ryker.AdvisoryLock
  alias Ryker.Continuity
  alias Ryker.Knowledge
  alias Ryker.Learning
  alias Ryker.Memories
  alias Ryker.Repo
  alias Ryker.Work
  require Logger

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
          routing_examples: non_neg_integer(),
          routing_responses: non_neg_integer(),
          work_examples: non_neg_integer(),
          episode_histories: non_neg_integer(),
          feedback: non_neg_integer(),
          improvement: non_neg_integer(),
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

  # Each phase commits on its own, and one that fails is logged and the pass
  # goes on: chained, one failing phase stopped every later one on every pass,
  # deleting the examples a person turned off included. The pass still
  # reports which phases failed.
  @phases ~w(expiring reviews operational closed_work history audit examples)a

  defp prune_in_transactions(settings) do
    {result, failed} =
      Enum.reduce(@phases, {empty_result(), []}, fn phase, {result, failed} ->
        case run_phase(phase, result, settings) do
          {:ok, result} -> {result, failed}
          :error -> {result, [phase | failed]}
        end
      end)

    broadcast_history_pruned({:ok, result})

    case failed do
      [] -> {:ok, result}
      failed -> {:error, {:retention_phases_failed, Enum.reverse(failed)}}
    end
  end

  defp run_phase(phase, result, settings) do
    case in_transactions(phase, fn -> prune_phase(phase, result, settings) end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> phase_failed(phase, inspect(reason))
    end
  rescue
    error -> phase_failed(phase, Exception.format_banner(:error, error))
  end

  # Reviews open one workspace per transaction (`Reviews.refresh_all_reviews/1`),
  # so a pass holds the review lock no longer than one workspace takes.
  defp in_transactions(:reviews, phase), do: phase.()
  defp in_transactions(_phase, phase), do: Repo.transaction(phase)

  defp phase_failed(phase, reason) do
    Logger.error("retention phase #{phase} failed: #{reason}")
    :error
  end

  defp prune_phase(:expiring, result, settings), do: prune_expiring_resources(result, settings)

  # After pruning, so no review opens on a fact the pass just removed, and the
  # ones naming it are dismissed.
  defp prune_phase(:reviews, result, settings) do
    seconds = min(settings.conversation_memory_seconds, @memory_review_seconds)
    with {:ok, _created} <- Memories.Reviews.refresh_all_reviews(seconds), do: {:ok, result}
  end

  defp prune_phase(:operational, result, settings), do: prune_operational(result, settings)
  defp prune_phase(:closed_work, result, settings), do: prune_closed_work(result, settings)
  defp prune_phase(:history, result, settings), do: prune_history(result, settings)
  defp prune_phase(:audit, result, settings), do: prune_audit(result, settings)

  defp prune_phase(:examples, result, settings),
    do: result |> prune_routing_examples(settings) |> prune_work_examples(settings)

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

  # A rule, preference or guidance that ended keeps only a digest of its words
  # (`Ryker.Behaviors.redact!/3`) and goes at the history horizon, as a
  # finished schedule does. None was ever pruned, and each kept its source
  # episode's whole history alive with it (2026-10-04 review).
  @ended_behaviors %{
    table: "operator_behaviors",
    where: "status IN ('deleted', 'superseded', 'expired')",
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

    {:ok, compacted} =
      Continuity.Compaction.compact_in_transaction(
        min(memory_seconds, @summary_compaction_seconds),
        memory_seconds
      )

    memory = execute_count(@prune_operational_memory, [memory_seconds])
    rollups = prune_expired("conversation_rollups")
    _drafts = prune_aged(@settled_summary_drafts, settings)
    _behaviors = prune_expired("operator_behaviors")
    _ended_behaviors = prune_aged(@ended_behaviors, settings)
    _schedules = prune_aged(@finished_schedules, settings)
    observations = execute_count(@clear_observation_notes, [memory_seconds])
    knowledge = Knowledge.KnowledgeRetention.prune_in_transaction(memory_seconds)

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

  # Every command of a session the worker discarded, whatever its state: Coop
  # never answers one whose lease ran out or whose placement ended, and only
  # succeeded and failed ones used to go, so a "delivered" or "uncertain" one
  # kept its session, placement and prompt for good (2026-10-04 review).
  @discarded_session_commands %{
    table: "coop_worker_commands",
    as: "command",
    join: "JOIN episode_work_sessions AS session ON session.id = command.session_id",
    where: """
    session.cleanup_status = 'discarded'
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
    WHERE session.execution_kind IN ('admission', 'learning', 'improvement', 'knowledge')
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

  # A week's report is the record that the week was sent, which the scheduler
  # reads for the latest send time, at most a week old; it stays two weeks
  # whatever the horizon. One still being posted is custody and never goes.
  @finished_weekly_reports %{
    table: "weekly_reports",
    where: "status <> 'pending' AND due_at < clock_timestamp() - interval '14 days'",
    age: "updated_at",
    horizon: :operational_data_seconds
  }

  # Feedback on an answer ages from when Ryker recorded it, not from when the
  # source says it happened: a redelivered old event is still recent news.
  @recorded_feedback %{
    table: "answer_feedback",
    age: "inserted_at",
    horizon: :operational_data_seconds,
    limit: 500
  }

  # A request people were unhappy with (`Ryker.Improvement`) ages from its last
  # change, like the feedback it came from; an accepted case is training data
  # and ages from its acceptance over the routing examples window while those
  # are kept. It names its request without a foreign key, so it is written
  # out: nothing above reaches it, and it waits while a session of one of its
  # analysis runs is still on record, which cleanup removes first.
  @prune_improvement_candidates """
  WITH candidates AS (
    SELECT candidate.id
    FROM improvement_candidates AS candidate
    WHERE candidate.analysis <> 'running'
      AND (
        (candidate.status <> 'accepted'
          AND candidate.updated_at < clock_timestamp() - ($1 * interval '1 second'))
        OR (candidate.status = 'accepted'
          AND candidate.decided_at < clock_timestamp()
            - ((CASE WHEN $2 THEN $3 ELSE $1 END) * interval '1 second'))
      )
      AND NOT EXISTS (
        SELECT 1 FROM improvement_analysis_runs AS run
        JOIN episode_work_sessions AS session ON session.improvement_run_id = run.id
        WHERE run.candidate_id = candidate.id
      )
    ORDER BY candidate.updated_at, candidate.id
    LIMIT 100
    FOR UPDATE OF candidate SKIP LOCKED
  )
  DELETE FROM improvement_candidates AS candidate
  USING candidates
  WHERE candidate.id = candidates.id
  """

  # The exact prompt and answer of an analysis turn quote people's messages:
  # their words go at the operational horizon once the turn has stopped (or
  # never started), and the run keeps only its receipts. Only the analysis
  # lane records a stop, and it exists only while there is a learning policy
  # and Work, so a run out at Coop when the lane went kept its words for good
  # (2026-10-04 review): past the longest an attempt can run, Coop's longest
  # turn and the longest execution timeout, its words go at the horizon on
  # that local proof. A lane that comes back reads the empty prompt and stops
  # the run (`Ryker.Improvement.Executor`).
  @longest_analysis_seconds 24 * 3_600 + 1_800
  @prune_improvement_runs """
  WITH candidates AS (
    SELECT run.id
    FROM improvement_analysis_runs AS run
    WHERE run.pruned_at IS NULL
      AND (
        ((run.remote_stopped_at IS NOT NULL OR run.started_at IS NULL)
          AND run.updated_at < clock_timestamp() - ($1 * interval '1 second'))
        OR run.started_at < clock_timestamp() - (greatest($1, $2) * interval '1 second')
      )
    ORDER BY run.updated_at, run.id
    LIMIT 100
    FOR UPDATE OF run SKIP LOCKED
  )
  UPDATE improvement_analysis_runs AS run
  SET prompt = NULL, result = NULL, pruned_at = clock_timestamp()
  FROM candidates
  WHERE run.id = candidates.id
  """

  # A repository knowledge turn that stopped ages out at the operational
  # horizon once cleanup removed its session; the run that wrote the
  # repository's current RYKER.md stays with it (`Ryker.RepositoryKnowledge`).
  @prune_knowledge_runs """
  WITH candidates AS (
    SELECT run.id
    FROM repository_knowledge_runs AS run
    WHERE (run.remote_stopped_at IS NOT NULL OR run.started_at IS NULL)
      AND run.updated_at < clock_timestamp() - ($1 * interval '1 second')
      AND NOT EXISTS (
        SELECT 1 FROM episode_work_sessions AS session WHERE session.knowledge_run_id = run.id
      )
      AND NOT EXISTS (
        SELECT 1 FROM repository_knowledge AS entry WHERE entry.document_run_id = run.id
      )
    ORDER BY run.updated_at, run.id
    LIMIT 100
    FOR UPDATE OF run SKIP LOCKED
  )
  DELETE FROM repository_knowledge_runs AS run
  USING candidates
  WHERE run.id = candidates.id
  """

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
      rejections = NULL,
      operational_pruned_at = clock_timestamp()
  FROM candidates WHERE attempt.id = candidates.id
  """

  # Written out because a comparison holds the local routing model's answer to
  # its message's prompt and has no horizon of its own: it goes as soon as its
  # message's bodies are pruned, whether it was ever asked or not.
  @prune_local_routing_comparisons """
  WITH candidates AS (
    SELECT comparison.id FROM local_routing_comparisons AS comparison
    JOIN ingress_inbox_entries AS input ON input.id = comparison.input_id
    WHERE input.operational_pruned_at IS NOT NULL
    ORDER BY comparison.inserted_at, comparison.id LIMIT 100
    FOR UPDATE OF comparison SKIP LOCKED
  )
  DELETE FROM local_routing_comparisons AS comparison
  USING candidates WHERE comparison.id = candidates.id
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
    worker_commands = prune_aged(@discarded_session_commands, settings)
    worker_events = prune_aged(@discarded_worker_events, settings)
    _non_work_sessions = execute_count(@prune_non_work_sessions, [cutoff])
    routing_responses = prune_aged(@delivered_routing_responses, settings)
    _weekly_reports = prune_aged(@finished_weekly_reports, settings)
    feedback = prune_aged(@recorded_feedback, settings)

    _improvement_runs =
      execute_count(@prune_improvement_runs, [cutoff, @longest_analysis_seconds])

    _knowledge_runs = execute_count(@prune_knowledge_runs, [cutoff])

    improvement =
      execute_count(@prune_improvement_candidates, [
        cutoff,
        settings.routing_examples_enabled,
        settings.routing_examples_seconds
      ])

    _github_events = prune_aged(@processed_github_events, settings)

    configuration_sessions =
      execute_count(@prune_configuration_sessions, [~w(saved cancelled expired), cutoff])

    operational_inputs =
      execute_count(@prune_operational_inputs, [~w(decided superseded), cutoff])

    learning_artifacts = Learning.prune_in_transaction(settings.conversation_memory_seconds)
    _admission_artifacts = execute_count(@prune_admission_artifacts)
    _local_routing_comparisons = execute_count(@prune_local_routing_comparisons)
    _status_receipts = prune_aged(@finished_status_receipts, settings)
    operational_turns = execute_count(@prune_operational_turns, [@terminal_turn_states, cutoff])
    _activity_evidence = Work.ActivityRetention.prune()
    _input_artifact_references = execute_count(@prune_input_artifact_references)
    _work_artifact_references = execute_count(@prune_work_artifact_references)
    _state_tool_calls = execute_count(@prune_state_tool_calls)
    output_artifacts = prune_aged(@pruned_turn_outputs, settings)
    input_artifacts = prune_aged(@unreferenced_input_artifacts, settings)

    %{
      result
      | configuration_sessions: configuration_sessions,
        conversation_memory: result.conversation_memory + learning_artifacts,
        feedback: feedback,
        improvement: improvement,
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
    _cases = Memories.Cases.capture_many(ids)

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
    %{
      table: "failure_dismissals",
      age: "left_at",
      horizon: :audit_data_seconds,
      key: ~w(kind ref)
    },
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

  # A message no episode took, once its routing is done. It stays while a
  # routing session for it is still being closed: deleting it emptied the
  # session's input, and such a session could never be closed or pruned.
  @orphan_inputs %{
    table: "ingress_inbox_entries",
    as: "input",
    where: """
    input.episode_id IS NULL
      AND input.operational_pruned_at IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM delivery_routing_responses routed WHERE routed.input_id = input.id)
      AND NOT EXISTS (SELECT 1 FROM episode_state_record_responses response WHERE response.inbox_entry_id = input.id)
      AND NOT EXISTS (
        SELECT 1 FROM episode_work_sessions session
        WHERE session.admission_input_id = input.id AND session.cleanup_status <> 'discarded'
      )
    """,
    age: "updated_at",
    horizon: :audit_data_seconds
  }

  # Written out because it chooses whole episodes, not rows. A button answer
  # routed away from the task that asked is this episode's input while the
  # answer row still points at it, so the episode waits for that answer to go
  # with the asking task's history.
  @audit_candidates """
  SELECT episode.id::text
  FROM episode_kernel_episodes AS episode
  WHERE episode.history_pruned_at IS NOT NULL
    AND episode.updated_at < clock_timestamp() - ($1 * interval '1 second')
    AND NOT EXISTS (
      SELECT 1 FROM episode_kernel_episodes child WHERE child.linked_episode_id = episode.id
    )
    AND NOT EXISTS (
      SELECT 1 FROM ingress_inbox_entries input
      JOIN episode_state_record_responses response ON response.inbox_entry_id = input.id
      WHERE input.episode_id = episode.id
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

  # Routing examples: redacted copies of routing decisions kept for training
  # (`Ryker.RoutingExamples`). They name the rows they were copied from
  # without a foreign key, so nothing above reaches them: only their own
  # window, counted from the decision, or turning keeping them off, which
  # takes every one. Written out because the horizon is one branch of an OR.
  @prune_routing_examples """
  WITH candidates AS (
    SELECT id
    FROM routing_examples
    WHERE NOT $1 OR decided_at < clock_timestamp() - ($2 * interval '1 second')
    ORDER BY decided_at, id
    LIMIT 1000
    FOR UPDATE SKIP LOCKED
  )
  DELETE FROM routing_examples AS example
  USING candidates
  WHERE example.id = candidates.id
  """

  defp prune_routing_examples(result, settings) do
    count =
      execute_count(@prune_routing_examples, [
        settings.routing_examples_enabled,
        settings.routing_examples_seconds
      ])

    %{result | routing_examples: count}
  end

  # Work examples (`Ryker.WorkExamples`) leave the same way: only their own
  # window, counted from when the turn settled, or turning keeping them off.
  # Their copied feedback goes with them by its foreign key.
  @prune_work_examples """
  WITH candidates AS (
    SELECT id
    FROM work_examples
    WHERE NOT $1 OR settled_at < clock_timestamp() - ($2 * interval '1 second')
    ORDER BY settled_at, id
    LIMIT 1000
    FOR UPDATE SKIP LOCKED
  )
  DELETE FROM work_examples AS example
  USING candidates
  WHERE example.id = candidates.id
  """

  defp prune_work_examples(result, settings) do
    count =
      execute_count(@prune_work_examples, [
        settings.work_examples_enabled,
        settings.work_examples_seconds
      ])

    %{result | work_examples: count}
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
    key = Map.get(rule, :key, ["id"])
    selected = Enum.map_join(key, ", ", &"#{name}.#{&1}")
    matched = Enum.map_join(key, " AND ", &"#{name}.#{&1} = candidates.#{&1}")

    condition =
      case Map.get(rule, :where) do
        nil -> older
        where -> "(#{where}) AND #{older}"
      end

    execute_count(
      """
      WITH candidates AS (
        SELECT #{selected}
        FROM #{source} #{Map.get(rule, :join, "")}
        WHERE #{condition}
        ORDER BY #{name}.#{rule.age}, #{selected}
        LIMIT #{Map.get(rule, :limit, 100)}
        FOR UPDATE OF #{name} SKIP LOCKED
      )
      DELETE FROM #{source}
      USING candidates
      WHERE #{matched}
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

  defp advisory_lock?, do: AdvisoryLock.try_session(@advisory_lock)
  defp release_advisory_lock!, do: AdvisoryLock.release_session(@advisory_lock)

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
      routing_examples: 0,
      routing_responses: 0,
      work_examples: 0,
      episode_histories: 0,
      feedback: 0,
      improvement: 0,
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
    horizons =
      ~w(audit_data_seconds closed_work_seconds conversation_memory_seconds episode_history_seconds operational_data_seconds routing_examples_seconds work_examples_seconds)a

    switches = [:routing_examples_enabled, :work_examples_enabled]

    valid =
      Map.keys(settings) |> Enum.sort() == Enum.sort(switches ++ horizons) and
        Enum.all?(switches, &is_boolean(settings[&1])) and
        Enum.all?(horizons, &(is_integer(settings[&1]) and settings[&1] > 0)) and
        horizons_ordered?(settings)

    if valid, do: {:ok, settings}, else: {:error, {:invalid_retention_data, :settings}}
  end

  defp settings(_settings), do: {:error, {:invalid_retention_data, :settings}}

  defp horizons_ordered?(settings) do
    settings.operational_data_seconds <= settings.closed_work_seconds and
      settings.closed_work_seconds <= settings.episode_history_seconds and
      settings.episode_history_seconds <= settings.audit_data_seconds and
      settings.operational_data_seconds <= settings.conversation_memory_seconds
  end

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Subscribes the caller to retention passes: `{:history_pruned, kinds}` once a
  pass removed or redacted retained history and committed. `kinds` names what
  it touched (the keys of `t:result/0` with a count above zero), never a row.
  """
  def subscribe_pruning, do: Ryker.PubSub.subscribe(pruning_topic())

  def unsubscribe_pruning, do: Ryker.PubSub.unsubscribe(pruning_topic())

  defp pruning_topic, do: "retention:pruning"

  defp broadcast_history_pruned({:ok, %{} = result}) do
    case for({kind, count} <- result, is_integer(count) and count > 0, do: kind) do
      [] ->
        :ok

      kinds ->
        kinds = Enum.sort(kinds)

        Repo.after_commit(fn ->
          Ryker.PubSub.broadcast(pruning_topic(), {:history_pruned, kinds})
        end)
    end
  end

  defp broadcast_history_pruned(_not_pruned), do: :ok
end
