defmodule Ryker.Repo.Migrations.AddRepositoryKnowledge do
  use Ecto.Migration

  # Andrew, 2026-09-27, of the RYKER.md pull requests setup opened: "those are
  # pretty weak summaries for the repo, should we do something better than
  # that?! also when those are updated? everything is hash-pinned for some
  # reason, even paths to folders". Setup scanned the file list once, linked
  # every path to the commit it read, and never looked again.
  #
  # repository_knowledge: one row per repository, the custody of its RYKER.md
  # (`Ryker.RepositoryKnowledge`). `phase` says what is wanted next: nothing
  # but the daily check (`idle`, due at `next_check_at`), a model turn that
  # writes the document (`write`), or proposing the written document on GitHub
  # (`publish`). The last document Ryker wrote is kept with the commit it read
  # and who wrote it: a model, or the file-list outline when no model could
  # finish. A worker leases a row for each step, like every other lane.
  #
  # repository_knowledge_runs: each model turn that read a repository, with
  # the exact prompt and answer, frozen like a self-analysis run. Each runs in
  # a worker session of its own (execution kind `knowledge`) over the
  # repository, read-only, at the commit it names; cleanup closes it once the
  # run has stopped.
  #
  # Setup no longer scans or publishes: it pins the repository and hands
  # RYKER.md to this lane, so a repository caught mid-scan or mid-publish is
  # set up (its commit is pinned) or starts over (it is not).
  #
  # Rolling back refuses while a session or a metered turn of this lane is
  # kept: the previous release has nowhere to keep them.

  @phases ~w(idle write publish)
  @run_statuses ~w(prepared responded applied rejected stale)

  def up do
    create table(:repository_knowledge, primary_key: false) do
      add(:repository_ref, :text, primary_key: true)
      add(:phase, :text, null: false, default: "idle")
      add(:reason, :text)
      add(:requested_by, :text)
      add(:start_count, :integer, null: false, default: 0)
      add(:start_limit, :integer, null: false, default: 2)
      add(:lease_ref, :uuid)
      add(:lease_owner, :text)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:heartbeat_at, :utc_datetime_usec)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:next_check_at, :utc_datetime_usec)
      add(:checked_at, :utc_datetime_usec)
      add(:document, :text)
      add(:document_sha256, :text)
      add(:document_commit, :text)
      add(:document_by, :text)
      add(:document_at, :utc_datetime_usec)
      add(:document_run_id, :uuid)
      add(:dropped_count, :integer)
      add(:published_at, :utc_datetime_usec)
      add(:publication, :text)
      add(:pull_request_url, :text)
      add(:pull_request_number, :bigint)
      add(:pull_request_state, :text)
      add(:error_code, :text)
      add(:error, :text)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(:repository_knowledge, :repository_knowledge_valid,
        check: """
        char_length(repository_ref) BETWEEN 1 AND 64
        AND phase IN (#{quoted(@phases)})
        AND start_count BETWEEN 0 AND start_limit AND start_limit BETWEEN 1 AND 8
        AND (lease_ref IS NULL) = (lease_owner IS NULL)
        AND (lease_ref IS NULL) = (lease_expires_at IS NULL)
        AND (lease_owner IS NULL OR char_length(lease_owner) BETWEEN 1 AND 1024)
        AND (reason IS NULL OR char_length(reason) BETWEEN 1 AND 512)
        AND (requested_by IS NULL OR char_length(requested_by) BETWEEN 1 AND 256)
        AND (document IS NULL) = (document_sha256 IS NULL)
        AND (document IS NULL) = (document_commit IS NULL)
        AND (document IS NULL) = (document_by IS NULL)
        AND (document IS NULL) = (document_at IS NULL)
        AND (document IS NULL OR octet_length(document) BETWEEN 1 AND 128000)
        AND (document_sha256 IS NULL OR document_sha256 ~ '^[0-9a-f]{64}$')
        AND (document_commit IS NULL OR document_commit ~ '^[0-9a-f]{40}$')
        AND (document_by IS NULL OR document_by IN ('model', 'outline'))
        AND (phase <> 'publish' OR document IS NOT NULL)
        AND (published_at IS NULL OR document IS NOT NULL)
        AND (published_at IS NULL) = (publication IS NULL)
        AND (publication IS NULL OR publication IN ('opened', 'updated', 'unchanged'))
        AND (pull_request_url IS NULL OR pull_request_url ~ '^https://')
        AND (pull_request_number IS NULL OR pull_request_number > 0)
        AND (pull_request_url IS NULL) = (pull_request_number IS NULL)
        AND (pull_request_url IS NULL) = (pull_request_state IS NULL)
        AND (pull_request_state IS NULL OR pull_request_state IN ('open', 'merged', 'closed'))
        AND (dropped_count IS NULL OR dropped_count >= 0)
        AND (error_code IS NULL) = (error IS NULL)
        AND (error_code IS NULL OR char_length(error_code) BETWEEN 1 AND 128)
        AND (error IS NULL OR char_length(error) BETWEEN 1 AND 1024)
        """
      )
    )

    create(index(:repository_knowledge, [:phase, :next_attempt_at]))
    create(index(:repository_knowledge, [:next_check_at]))

    create table(:repository_knowledge_runs, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :repository_ref,
        references(:repository_knowledge,
          column: :repository_ref,
          type: :text,
          on_delete: :delete_all
        ),
        null: false
      )

      add(:generation, :integer, null: false)
      add(:status, :text, null: false)
      add(:source_commit, :text, null: false)
      add(:policy, :text, null: false)
      add(:policy_digest, :text, null: false)
      add(:transport, :text, null: false)
      add(:conversation_ref, :text, null: false)
      add(:prompt, :text, null: false)
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
      add(:document, :text)
      add(:dropped_count, :integer)
      add(:error_code, :text)
      add(:reconcile_attempt_count, :integer, null: false, default: 0)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(:repository_knowledge_runs, :repository_knowledge_run_valid,
        check: """
        generation >= 1
        AND status IN (#{quoted(@run_statuses)})
        AND source_commit ~ '^[0-9a-f]{40}$'
        AND char_length(policy) BETWEEN 1 AND 160
        AND policy_digest ~ '^[0-9a-f]{64}$'
        AND char_length(transport) BETWEEN 1 AND 64
        AND char_length(conversation_ref) BETWEEN 1 AND 1024
        AND prompt_sha256 ~ '^[0-9a-f]{64}$'
        AND (result_sha256 IS NULL OR result_sha256 ~ '^[0-9a-f]{64}$')
        AND (submit_revision IS NULL OR submit_revision > 0)
        AND (candidate_attempt IS NULL OR candidate_attempt > 0)
        AND (coop_turn_id IS NULL OR char_length(coop_turn_id) BETWEEN 1 AND 1024)
        AND (stop_receipt IS NULL) = (remote_stopped_at IS NULL)
        AND (status <> 'applied' OR document IS NOT NULL)
        AND (document IS NULL OR octet_length(document) BETWEEN 1 AND 128000)
        AND (dropped_count IS NULL OR dropped_count >= 0)
        AND reconcile_attempt_count >= 0
        """
      )
    )

    create(unique_index(:repository_knowledge_runs, [:repository_ref, :generation]))
    create(index(:repository_knowledge_runs, [:updated_at, :id]))

    # A session of a knowledge run reads exactly one repository at one commit:
    # no episode, message, learning or self-analysis run, companion or
    # workspace task.
    alter table(:episode_work_sessions) do
      add(:knowledge_run_id, references(:repository_knowledge_runs, type: :uuid))
    end

    drop(constraint(:episode_work_sessions, :episode_work_session_owner_valid))

    create(
      constraint(:episode_work_sessions, :episode_work_session_owner_valid,
        check: """
        (execution_kind = 'work' AND episode_id IS NOT NULL AND admission_input_id IS NULL
          AND learning_run_id IS NULL AND improvement_run_id IS NULL
          AND knowledge_run_id IS NULL)
        OR (execution_kind = 'admission' AND episode_id IS NULL AND learning_run_id IS NULL
          AND improvement_run_id IS NULL AND knowledge_run_id IS NULL AND repository_ref IS NULL
          AND repository_context IS NULL AND workspace_task IS NULL)
        OR (execution_kind = 'learning' AND episode_id IS NULL AND admission_input_id IS NULL
          AND learning_run_id IS NOT NULL AND improvement_run_id IS NULL
          AND knowledge_run_id IS NULL AND repository_ref IS NULL
          AND repository_context IS NULL AND workspace_task IS NULL AND authority_digest IS NULL)
        OR (execution_kind = 'improvement' AND episode_id IS NULL AND admission_input_id IS NULL
          AND learning_run_id IS NULL AND improvement_run_id IS NOT NULL
          AND knowledge_run_id IS NULL AND repository_ref IS NULL
          AND repository_context IS NULL AND workspace_task IS NULL AND authority_digest IS NULL)
        OR (execution_kind = 'knowledge' AND episode_id IS NULL AND admission_input_id IS NULL
          AND learning_run_id IS NULL AND improvement_run_id IS NULL
          AND knowledge_run_id IS NOT NULL AND repository_ref IS NOT NULL
          AND repository_source IS NOT NULL AND repository_context IS NULL
          AND workspace_task IS NULL AND authority_digest IS NULL)
        """
      )
    )

    create(
      unique_index(:episode_work_sessions, [:knowledge_run_id],
        name: :episode_work_sessions_knowledge_run_id_index,
        where: "execution_kind = 'knowledge'"
      )
    )

    create(
      unique_index(:episode_work_sessions, [:external_ref],
        name: :knowledge_session_external_identity,
        where: "execution_kind = 'knowledge'"
      )
    )

    # A knowledge turn is metered like a self-analysis turn.
    drop(constraint(:execution_usage, :execution_usage_identity_valid))

    create(
      constraint(:execution_usage, :execution_usage_identity_valid,
        check: """
        kind IN ('work', 'admission', 'learning', 'improvement', 'knowledge')
        AND execution_mode IN ('live', 'shadow')
        AND octet_length(generation) BETWEEN 1 AND 64
        """
      )
    )

    # Setup ends once the repository's commit is pinned; RYKER.md is this
    # lane's. A repository caught reading or publishing is set up when its
    # commit was pinned, and starts over when it was not.
    execute("""
    UPDATE #{qualified("repository_settings")}
    SET onboarding_state = CASE WHEN source_commit IS NULL THEN 'pending' ELSE 'ready' END
    WHERE onboarding_state IN ('scanning', 'publishing')
    """)

    drop(constraint(:repository_settings, :repository_github_state_valid))

    create(
      constraint(:repository_settings, :repository_github_state_valid,
        check: """
        github_access IN ('available', 'suspended', 'removed')
        AND onboarding_state IN ('pending', 'cloning', 'ready', 'blocked')
        """
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM #{qualified("episode_work_sessions")} WHERE execution_kind = 'knowledge')
         OR EXISTS (SELECT 1 FROM #{qualified("execution_usage")} WHERE kind = 'knowledge') THEN
        RAISE EXCEPTION 'repository knowledge sessions are kept; the previous release has nowhere to keep them';
      END IF;
    END
    $$
    """)

    drop(constraint(:repository_settings, :repository_github_state_valid))

    create(
      constraint(:repository_settings, :repository_github_state_valid,
        check: """
        github_access IN ('available', 'suspended', 'removed')
        AND onboarding_state IN ('pending', 'cloning', 'scanning', 'publishing', 'ready', 'blocked')
        """
      )
    )

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

    drop(index(:episode_work_sessions, [], name: :knowledge_session_external_identity))
    drop(index(:episode_work_sessions, [], name: :episode_work_sessions_knowledge_run_id_index))
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

    alter table(:episode_work_sessions) do
      remove(:knowledge_run_id)
    end

    drop(table(:repository_knowledge_runs))
    drop(table(:repository_knowledge))
  end

  defp quoted(values), do: Enum.map_join(values, ", ", &"'#{&1}'")

  defp qualified(name) do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."#{name}")
  end
end
