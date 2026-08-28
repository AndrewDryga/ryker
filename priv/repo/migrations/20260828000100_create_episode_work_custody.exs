defmodule Responder.Repo.Migrations.CreateEpisodeWorkCustody do
  use Ecto.Migration

  def change do
    create table(:episode_work_sessions, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :episode_id,
        references(:episode_kernel_episodes, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:policy, :text, null: false)
      add(:policy_digest, :text, null: false)
      add(:external_ref, :text, null: false)
      add(:generation, :bigint, null: false, default: 1)
      add(:create_generation, :bigint, null: false, default: 1)
      add(:coop_session_id, :text)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:episode_work_sessions, [:episode_id, :generation]))
    create(unique_index(:episode_work_sessions, [:id, :episode_id]))

    create(
      unique_index(:episode_work_sessions, [:coop_session_id],
        where: "coop_session_id IS NOT NULL"
      )
    )

    create(
      constraint(:episode_work_sessions, :episode_work_session_identity_valid,
        check:
          "char_length(policy) > 0 AND generation > 0 AND create_generation > 0" <>
            " AND char_length(policy_digest) = 64 AND char_length(external_ref) > 0"
      )
    )

    create table(:episode_work_turns, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(
        :episode_id,
        references(:episode_kernel_episodes, type: :uuid, on_delete: :restrict),
        null: false
      )

      add(:turn_ref, :text, null: false)
      add(:status, :text, null: false, default: "pending")

      add(
        :session_id,
        references(:episode_work_sessions,
          type: :uuid,
          on_delete: :restrict,
          with: [episode_id: :episode_id],
          name: :episode_work_turn_session_episode_fkey
        ),
        null: false
      )

      add(:submit_generation, :bigint, null: false, default: 1)
      add(:validation_generation, :bigint, null: false, default: 1)
      add(:cancel_generation, :bigint, null: false, default: 1)
      add(:cancel_expected_revision, :bigint)
      add(:close_expected_revision, :bigint)
      add(:submission, :text)
      add(:submission_fingerprint, :text)
      add(:coop_turn_id, :text)
      add(:candidate, :text)
      add(:candidate_sha256, :text)
      add(:candidate_attempt, :bigint)
      add(:validation_intent, :text)
      add(:validation_intent_fingerprint, :text)
      add(:validation_receipt, :text)
      add(:cancellation_intent, :text)
      add(:cancellation_intent_fingerprint, :text)
      add(:cancellation_receipt, :text)
      add(:cancellation_receipt_fingerprint, :text)
      add(:remote_operation_kind, :text)
      add(:remote_operation_key, :text)
      add(:remote_operation_revision, :bigint)
      add(:result_ref, :text)
      add(:delivery_ref, :text)
      add(:delivery_document, :text)
      add(:delivery_fingerprint, :text)
      add(:continuation, :text)
      add(:external_receipt, :text)
      add(:external_receipt_fingerprint, :text)
      add(:work_attempt_count, :bigint, null: false, default: 0)
      add(:cancel_attempt_count, :bigint, null: false, default: 0)
      add(:delivery_attempt_count, :bigint, null: false, default: 0)
      add(:lease_ref, :text)
      add(:lease_owner, :text)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:next_attempt_at, :utc_datetime_usec)
      add(:last_error_code, :text)
      add(:last_error_detail, :text)
      add(:accepted_at, :utc_datetime_usec)
      add(:cancelled_at, :utc_datetime_usec)
      add(:delivered_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:episode_work_turns, [:episode_id, :turn_ref]))
    create(index(:episode_work_turns, [:session_id]))

    create(unique_index(:episode_work_turns, [:coop_turn_id], where: "coop_turn_id IS NOT NULL"))
    create(unique_index(:episode_work_turns, [:result_ref], where: "result_ref IS NOT NULL"))
    create(unique_index(:episode_work_turns, [:delivery_ref], where: "delivery_ref IS NOT NULL"))

    create(index(:episode_work_turns, [:episode_id, :inserted_at]))

    create(
      index(
        :episode_work_turns,
        [:status, :next_attempt_at, :lease_expires_at, :inserted_at, :id],
        name: :episode_work_turns_claimable
      )
    )

    create(
      constraint(:episode_work_turns, :episode_work_turn_identity_valid,
        check: "char_length(turn_ref) > 0"
      )
    )

    create(
      constraint(:episode_work_turns, :episode_work_turn_generations_valid,
        check:
          "submit_generation > 0 AND validation_generation > 0 AND cancel_generation > 0 " <>
            "AND work_attempt_count >= 0 AND cancel_attempt_count >= 0 " <>
            "AND delivery_attempt_count >= 0 " <>
            "AND (cancel_expected_revision IS NULL OR cancel_expected_revision > 0) " <>
            "AND (close_expected_revision IS NULL OR close_expected_revision > 0)"
      )
    )

    create(
      constraint(:episode_work_turns, :episode_work_turn_cancellation_valid,
        check: """
        (
          cancellation_intent IS NULL
          AND cancellation_intent_fingerprint IS NULL
          AND cancellation_receipt IS NULL
          AND cancellation_receipt_fingerprint IS NULL
          AND cancelled_at IS NULL
        )
        OR
        (
          cancellation_intent IS NOT NULL
          AND char_length(cancellation_intent_fingerprint) = 64
          AND (
            (
              cancellation_receipt IS NULL
              AND cancellation_receipt_fingerprint IS NULL
              AND cancelled_at IS NULL
            )
            OR
            (
              cancellation_receipt IS NOT NULL
              AND char_length(cancellation_receipt_fingerprint) = 64
              AND cancelled_at IS NOT NULL
            )
          )
        )
        """
      )
    )

    create(
      constraint(:episode_work_turns, :episode_work_turn_submission_valid,
        check: """
        (submission IS NULL AND submission_fingerprint IS NULL)
        OR
        (submission IS NOT NULL AND char_length(submission_fingerprint) = 64)
        """
      )
    )

    create(
      constraint(:episode_work_turns, :episode_work_turn_remote_operation_valid,
        check: """
        (
          remote_operation_kind IS NULL
          AND remote_operation_key IS NULL
          AND remote_operation_revision IS NULL
        )
        OR
        (
          remote_operation_kind = 'create_session'
          AND char_length(remote_operation_key) > 0
          AND remote_operation_revision IS NULL
          AND status IN ('pending', 'cancel_pending')
        )
        OR
        (
          remote_operation_kind = 'submit_turn'
          AND char_length(remote_operation_key) > 0
          AND remote_operation_revision > 0
          AND status IN ('pending', 'cancel_pending')
        )
        """
      )
    )

    create(
      constraint(:episode_work_turns, :episode_work_turn_validation_intent_valid,
        check: """
        (validation_intent IS NULL AND validation_intent_fingerprint IS NULL)
        OR
        (validation_intent IS NOT NULL AND char_length(validation_intent_fingerprint) = 64)
        """
      )
    )

    create(
      constraint(:episode_work_turns, :episode_work_turn_candidate_valid,
        check: """
        (
          candidate IS NULL
          AND candidate_sha256 IS NULL
          AND candidate_attempt IS NULL
          AND validation_intent IS NULL
          AND validation_intent_fingerprint IS NULL
          AND validation_receipt IS NULL
          AND result_ref IS NULL
          AND accepted_at IS NULL
          AND continuation IS NULL
        )
        OR
        (
          candidate IS NOT NULL
          AND octet_length(candidate) <= 262144
          AND char_length(candidate_sha256) = 64
          AND candidate_attempt > 0
          AND validation_receipt IS NULL
          AND result_ref IS NULL
          AND accepted_at IS NULL
          AND continuation IS NULL
        )
        OR
        (
          candidate IS NOT NULL
          AND octet_length(candidate) <= 262144
          AND char_length(candidate_sha256) = 64
          AND candidate_attempt > 0
          AND validation_intent IS NOT NULL
          AND char_length(validation_intent_fingerprint) = 64
          AND char_length(validation_receipt) > 0
          AND char_length(result_ref) > 0
          AND accepted_at IS NOT NULL
          AND continuation IS NOT NULL
        )
        """
      )
    )

    create(
      constraint(:episode_work_turns, :episode_work_turn_delivery_valid,
        check: """
        (
          delivery_ref IS NULL
          AND delivery_document IS NULL
          AND delivery_fingerprint IS NULL
          AND external_receipt IS NULL
          AND external_receipt_fingerprint IS NULL
          AND delivered_at IS NULL
        )
        OR
        (
          char_length(delivery_ref) > 0
          AND delivery_document IS NOT NULL
          AND char_length(delivery_fingerprint) = 64
          AND (
            (
              external_receipt IS NULL
              AND external_receipt_fingerprint IS NULL
              AND delivered_at IS NULL
            )
            OR
            (
              external_receipt IS NOT NULL
              AND char_length(external_receipt_fingerprint) = 64
              AND delivered_at IS NOT NULL
            )
          )
        )
        """
      )
    )

    create(
      constraint(:episode_work_turns, :episode_work_turn_custody_valid,
        check: """
        status IN ('pending', 'cancel_pending', 'delivery_pending', 'settled', 'blocked', 'superseded')
        AND (
          (lease_ref IS NULL AND lease_owner IS NULL AND lease_expires_at IS NULL)
          OR
          (
            status IN ('pending', 'cancel_pending', 'delivery_pending')
            AND char_length(lease_ref) > 0
            AND char_length(lease_owner) > 0
            AND lease_expires_at IS NOT NULL
          )
        )
        AND (status IN ('pending', 'cancel_pending', 'delivery_pending') OR next_attempt_at IS NULL)
        AND (
          status <> 'cancel_pending'
          OR (
            cancellation_intent IS NOT NULL
            AND cancellation_receipt IS NULL
            AND cancelled_at IS NULL
          )
        )
        AND (
          status NOT IN ('delivery_pending', 'settled')
          OR (
            candidate IS NOT NULL
            AND validation_receipt IS NOT NULL
            AND result_ref IS NOT NULL
            AND accepted_at IS NOT NULL
          )
        )
        AND (
          status <> 'delivery_pending'
          OR (
            delivery_ref IS NOT NULL
            AND external_receipt IS NULL
            AND delivered_at IS NULL
          )
        )
        AND (
          status <> 'settled'
          OR delivery_ref IS NULL
          OR (external_receipt IS NOT NULL AND delivered_at IS NOT NULL)
        )
        """
      )
    )
  end
end
