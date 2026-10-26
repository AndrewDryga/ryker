defmodule Ryker.Work.CompletionReview.Run.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.Crypto
  alias Ryker.Work.CompletionReview.Run

  @insert_fields ~w(id turn_id generation candidate_sha256 ledger_sha256 progress_sha256 policy policy_digest prompt prompt_sha256 output_schema started_at)a
  @transition_fields ~w(status submit_revision coop_turn_id candidate_attempt result result_sha256 producer validation_receipt stop_receipt remote_stopped_at error_code)a

  def insert(attributes) do
    %Run{}
    |> cast(attributes, @insert_fields)
    |> put_change(:status, :prepared)
    |> validate_required(@insert_fields)
    |> validate_number(:generation, greater_than: 0)
    |> validate_length(:prompt, max: 524_288, count: :bytes)
    |> validate_length(:policy, max: 1_024, count: :codepoints)
    |> validate_format(:candidate_sha256, Crypto.sha256_hex_pattern())
    |> validate_format(:ledger_sha256, Crypto.sha256_hex_pattern())
    |> validate_format(:progress_sha256, Crypto.sha256_hex_pattern())
    |> validate_format(:policy_digest, Crypto.sha256_hex_pattern())
    |> validate_format(:prompt_sha256, Crypto.sha256_hex_pattern())
    |> foreign_key_constraint(:turn_id)
    |> unique_constraint([:turn_id, :generation])
    |> review_constraints()
  end

  def transition(%Run{} = run, attributes) do
    run
    |> cast(attributes, @transition_fields)
    |> validate_length(:result, max: 524_288, count: :bytes)
    |> validate_length(:coop_turn_id, max: 1_024, count: :codepoints)
    |> validate_length(:error_code, max: 120, count: :codepoints)
    |> review_constraints()
  end

  defp review_constraints(changeset) do
    changeset
    |> check_constraint(:status, name: :work_completion_reviews_state_valid)
    |> check_constraint(:prompt, name: :work_completion_reviews_content_valid)
  end
end
