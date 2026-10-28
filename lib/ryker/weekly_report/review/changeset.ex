defmodule Ryker.WeeklyReport.Review.Changeset do
  @moduledoc "Pure transitions of one weekly review and its single attempt."
  use Ryker, :changeset
  alias Ryker.WeeklyReport.Review

  @insert_fields ~w(identity conversation_ref settings_saved_at period_start period_end timezone
    deadline_at policy policy_digest prompt prompt_sha256 output_schema manifest
    source_turn_ids source_conversation_refs source_identities message_keys)a

  def insert(attributes) do
    %Review{status: :prepared}
    |> cast(attributes, @insert_fields)
    |> validate_required(
      @insert_fields --
        [
          :settings_saved_at,
          :source_turn_ids,
          :source_conversation_refs,
          :source_identities,
          :message_keys
        ]
    )
    |> validate_length(:identity, is: 64, count: :codepoints)
    |> validate_length(:conversation_ref, max: 1024, count: :codepoints)
    |> validate_length(:policy, max: 1024, count: :codepoints)
    |> validate_length(:prompt, max: 131_072, count: :bytes)
    |> review_constraints()
  end

  def claim(%Review{} = review, owner, lease_ref, expires_at),
    do: change(review, lease_owner: owner, lease_ref: lease_ref, lease_expires_at: expires_at)

  def renew(%Review{} = review, expires_at),
    do: change(review, lease_expires_at: expires_at)

  def release(%Review{} = review, next_at) do
    change(review,
      lease_owner: nil,
      lease_ref: nil,
      lease_expires_at: nil,
      next_attempt_at: next_at
    )
  end

  def begin(%Review{} = review, now), do: change(review, started_at: now)
  def freeze_submit(%Review{} = review, revision), do: change(review, submit_revision: revision)
  def bind_turn(%Review{} = review, id), do: change(review, coop_turn_id: id)

  def candidate(%Review{} = review, message, digest, attempt, producer) do
    change(review,
      status: :responded,
      result: message,
      result_sha256: digest,
      candidate_attempt: attempt,
      producer: producer
    )
  end

  def confirm(%Review{} = review, receipt), do: change(review, validation_receipt: receipt)

  def apply_result(%Review{} = review, recommendations),
    do: change(review, status: :applied, recommendations: recommendations, error_code: nil)

  def end_attempt(%Review{} = review, reason) do
    status = if is_nil(review.started_at), do: :stale, else: :rejected
    change(review, status: status, error_code: Atom.to_string(reason))
  end

  def stop(%Review{} = review, receipt, now),
    do: change(review, stop_receipt: receipt, remote_stopped_at: now)

  def reconciliation_failed(%Review{} = review),
    do: change(review, reconcile_attempt_count: review.reconcile_attempt_count + 1)

  defp review_constraints(changeset) do
    changeset
    |> unique_constraint(:identity)
    |> check_constraint(:status, name: :weekly_report_reviews_state_valid)
    |> check_constraint(:prompt, name: :weekly_report_reviews_content_valid)
  end
end
