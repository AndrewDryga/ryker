defmodule Ryker.Repo.Migrations.AddImprovementCandidates do
  use Ecto.Migration

  # Andrew, 2026-09-27: "use that sentiment as indirect feedback channel ... do
  # something about it (at very least see where users were frustrated to see
  # what happened and fix the issue). Ideally, we need evals building based on
  # sentiment and self-analysis without much of manual human reviews."
  #
  # improvement_candidates: one row per request (an episode, or a message
  # routing answered by itself) that got negative feedback, holding which kinds
  # of feedback it got, the model's diagnosis once Ryker analyzed it, and a
  # person's decision. Like routing examples it names the request without a
  # foreign key, so the history horizons never reach it; only its own window
  # does (`Ryker.Retention.Data`). An accepted case freezes the evidence it
  # was accepted on (`case_evidence`); `message_keys` and `conversation_refs`
  # name what that evidence and the analysis quote, so a person forgetting a
  # message, a topic or a channel erases them (`forgotten_at`).
  #
  # improvement_analysis_runs: each model turn that analyzed a candidate, with
  # the exact prompt it was given and the answer, frozen like a learning run.
  # Each runs in a worker session of its own (execution kind `improvement`),
  # which cleanup closes once the run has stopped.
  #
  # Rolling back refuses while any candidate is kept: the previous release has
  # nowhere to keep them, and no session of an analysis may still be open.

  @statuses ~w(open accepted dismissed)
  @analyses ~w(pending running done failed)
  @categories ~w(host_bug prompt_bug model_mistake not_a_problem unclear)
  @steps ~w(routing work delivery)
  @confidences ~w(high medium low)
  @run_statuses ~w(prepared responded applied rejected stale)

  def up do
    create table(:improvement_candidates, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:episode_id, :uuid)
      add(:input_id, :uuid)
      add(:request_ref, :text, null: false)
      add(:transport, :text, null: false)
      add(:conversation_ref, :text, null: false)
      add(:reasons, {:array, :text}, null: false, default: fragment("ARRAY[]::text[]"))
      add(:signal_count, :integer, null: false, default: 1)
      add(:first_signal_at, :utc_datetime_usec, null: false)
      add(:last_signal_at, :utc_datetime_usec, null: false)
      add(:status, :text, null: false, default: "open")
      add(:decided_at, :utc_datetime_usec)
      add(:decided_by, :text)
      add(:case_evidence, :text)
      add(:message_keys, {:array, :text}, null: false, default: fragment("ARRAY[]::text[]"))
      add(:conversation_refs, {:array, :text}, null: false, default: fragment("ARRAY[]::text[]"))
      add(:forgotten_at, :utc_datetime_usec)
      add(:analysis, :text, null: false, default: "pending")
      add(:start_count, :integer, null: false, default: 0)
      add(:start_limit, :integer, null: false, default: 3)
      add(:lease_ref, :uuid)
      add(:lease_owner, :text)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:heartbeat_at, :utc_datetime_usec)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:error_code, :text)
      add(:category, :text)
      add(:step, :text)
      add(:what_went_wrong, :text)
      add(:expected, :text)
      add(:confidence, :text)
      add(:analysis_target, :text)
      add(:analyzed_at, :utc_datetime_usec)
      add(:analysis_run_id, :uuid)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(:improvement_candidates, :improvement_candidate_valid,
        check: """
        num_nonnulls(episode_id, input_id) = 1
        AND char_length(request_ref) BETWEEN 1 AND 1024
        AND char_length(transport) BETWEEN 1 AND 64
        AND char_length(conversation_ref) BETWEEN 1 AND 1024
        AND signal_count >= 1
        AND status IN (#{quoted(@statuses)})
        AND (status = 'open') = (decided_at IS NULL)
        AND (decided_at IS NULL) = (decided_by IS NULL)
        AND (status = 'accepted' OR case_evidence IS NULL)
        AND analysis IN (#{quoted(@analyses)})
        AND start_count BETWEEN 0 AND start_limit AND start_limit BETWEEN 1 AND 16
        AND (analysis = 'running') = (lease_ref IS NOT NULL)
        AND (lease_ref IS NULL) = (lease_owner IS NULL)
        AND (lease_ref IS NULL) = (lease_expires_at IS NULL)
        AND (category IS NULL OR category IN (#{quoted(@categories)}))
        AND (step IS NULL OR step IN (#{quoted(@steps)}))
        AND (confidence IS NULL OR confidence IN (#{quoted(@confidences)}))
        AND (what_went_wrong IS NULL OR octet_length(what_went_wrong) BETWEEN 1 AND 8192)
        AND (expected IS NULL OR octet_length(expected) BETWEEN 1 AND 4096)
        AND (
          analysis <> 'done' OR forgotten_at IS NOT NULL OR (
            category IS NOT NULL AND step IS NOT NULL AND confidence IS NOT NULL
            AND what_went_wrong IS NOT NULL AND expected IS NOT NULL AND analyzed_at IS NOT NULL
          )
        )
        """
      )
    )

    create(unique_index(:improvement_candidates, [:episode_id]))
    create(unique_index(:improvement_candidates, [:input_id]))
    create(index(:improvement_candidates, [:status, :last_signal_at, :id]))
    create(index(:improvement_candidates, [:analysis, :next_attempt_at]))
    create(index(:improvement_candidates, [:updated_at, :id]))
    create(index(:improvement_candidates, [:message_keys], using: :gin))
    create(index(:improvement_candidates, [:conversation_refs], using: :gin))

    create table(:improvement_analysis_runs, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :candidate_id,
        references(:improvement_candidates, type: :uuid, on_delete: :delete_all),
        null: false
      )

      add(:generation, :integer, null: false)
      add(:status, :text, null: false)
      add(:policy, :text, null: false)
      add(:policy_digest, :text, null: false)
      add(:prompt, :text)
      add(:prompt_sha256, :text, null: false)
      add(:output_schema, :text, null: false)
      add(:manifest, :text, null: false)
      add(:started_at, :utc_datetime_usec)
      add(:submit_revision, :bigint)
      add(:coop_turn_id, :text)
      add(:candidate_attempt, :integer)
      add(:result, :text)
      add(:result_sha256, :text)
      add(:producer, :text)
      add(:validation_receipt, :text)
      add(:stop_receipt, :text)
      add(:remote_stopped_at, :utc_datetime_usec)
      add(:error_code, :text)
      add(:reconcile_attempt_count, :integer, null: false, default: 0)
      add(:pruned_at, :utc_datetime_usec)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(:improvement_analysis_runs, :improvement_analysis_run_valid,
        check: """
        generation >= 1
        AND status IN (#{quoted(@run_statuses)})
        AND char_length(policy) BETWEEN 1 AND 160
        AND policy_digest ~ '^[0-9a-f]{64}$'
        AND prompt_sha256 ~ '^[0-9a-f]{64}$'
        AND (prompt IS NOT NULL OR pruned_at IS NOT NULL)
        AND (result_sha256 IS NULL OR result_sha256 ~ '^[0-9a-f]{64}$')
        AND (submit_revision IS NULL OR submit_revision > 0)
        AND (candidate_attempt IS NULL OR candidate_attempt > 0)
        AND (coop_turn_id IS NULL OR char_length(coop_turn_id) BETWEEN 1 AND 1024)
        AND (stop_receipt IS NULL) = (remote_stopped_at IS NULL)
        AND reconcile_attempt_count >= 0
        """
      )
    )

    create(unique_index(:improvement_analysis_runs, [:candidate_id, :generation]))
    create(index(:improvement_analysis_runs, [:updated_at, :id]))

    # A session of an analysis run: no episode, message, learning run,
    # repository or workspace, exactly like a learning session.
    alter table(:episode_work_sessions) do
      add(:improvement_run_id, references(:improvement_analysis_runs, type: :uuid))
    end

    drop(constraint(:episode_work_sessions, :episode_work_session_owner_valid))

    create(
      constraint(:episode_work_sessions, :episode_work_session_owner_valid,
        check: """
        (execution_kind = 'work' AND episode_id IS NOT NULL AND admission_input_id IS NULL
          AND learning_run_id IS NULL AND improvement_run_id IS NULL)
        OR (execution_kind = 'admission' AND episode_id IS NULL AND learning_run_id IS NULL
          AND improvement_run_id IS NULL AND repository_ref IS NULL
          AND repository_context IS NULL AND workspace_task IS NULL)
        OR (execution_kind = 'learning' AND episode_id IS NULL AND admission_input_id IS NULL
          AND learning_run_id IS NOT NULL AND improvement_run_id IS NULL
          AND repository_ref IS NULL AND repository_context IS NULL AND workspace_task IS NULL
          AND authority_digest IS NULL)
        OR (execution_kind = 'improvement' AND episode_id IS NULL AND admission_input_id IS NULL
          AND learning_run_id IS NULL AND improvement_run_id IS NOT NULL
          AND repository_ref IS NULL AND repository_context IS NULL AND workspace_task IS NULL
          AND authority_digest IS NULL)
        """
      )
    )

    create(
      unique_index(:episode_work_sessions, [:improvement_run_id],
        name: :episode_work_sessions_improvement_run_id_index,
        where: "execution_kind = 'improvement'"
      )
    )

    create(
      unique_index(:episode_work_sessions, [:external_ref],
        name: :improvement_session_external_identity,
        where: "execution_kind = 'improvement'"
      )
    )

    # An analysis turn is metered like a learning turn.
    drop(constraint(:execution_usage, :execution_usage_identity_valid))

    create(
      constraint(:execution_usage, :execution_usage_identity_valid,
        check: """
        kind IN ('work', 'admission', 'learning', 'improvement')
        AND execution_mode IN ('live', 'shadow')
        AND octet_length(generation) BETWEEN 1 AND 64
        """
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("improvement_candidates")})
         OR EXISTS (SELECT 1 FROM #{qualified("episode_work_sessions")} WHERE execution_kind = 'improvement')
         OR EXISTS (SELECT 1 FROM #{qualified("execution_usage")} WHERE kind = 'improvement') THEN
        RAISE EXCEPTION 'requests to improve are kept; the previous release has nowhere to keep them';
      END IF;
    END
    $$
    """)

    drop(constraint(:execution_usage, :execution_usage_identity_valid))

    create(
      constraint(:execution_usage, :execution_usage_identity_valid,
        check: """
        kind IN ('work', 'admission', 'learning')
        AND execution_mode IN ('live', 'shadow')
        AND octet_length(generation) BETWEEN 1 AND 64
        """
      )
    )

    drop(index(:episode_work_sessions, [], name: :improvement_session_external_identity))

    drop(index(:episode_work_sessions, [], name: :episode_work_sessions_improvement_run_id_index))

    drop(constraint(:episode_work_sessions, :episode_work_session_owner_valid))

    create(
      constraint(:episode_work_sessions, :episode_work_session_owner_valid,
        check: """
        (execution_kind = 'work' AND episode_id IS NOT NULL AND admission_input_id IS NULL
          AND learning_run_id IS NULL)
        OR (execution_kind = 'admission' AND episode_id IS NULL AND learning_run_id IS NULL
          AND repository_ref IS NULL AND repository_context IS NULL AND workspace_task IS NULL)
        OR (execution_kind = 'learning' AND episode_id IS NULL AND admission_input_id IS NULL
          AND learning_run_id IS NOT NULL AND repository_ref IS NULL
          AND repository_context IS NULL AND workspace_task IS NULL AND authority_digest IS NULL)
        """
      )
    )

    alter table(:episode_work_sessions) do
      remove(:improvement_run_id)
    end

    drop(table(:improvement_analysis_runs))
    drop(table(:improvement_candidates))
  end

  defp quoted(values), do: Enum.map_join(values, ", ", &"'#{&1}'")

  defp qualified(name) do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."#{name}")
  end
end
