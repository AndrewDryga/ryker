defmodule Responder.Slack.TaskCardChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Responder.Slack.TaskCard

  @fields [
    :attempt_count,
    :card_checked_at,
    :card_fingerprint,
    :card_ui_revision,
    :channel_ref,
    :episode_id,
    :id,
    :last_error_code,
    :last_error_detail,
    :lease_expires_at,
    :lease_owner,
    :lease_ref,
    :message_ref,
    :next_attempt_at,
    :record_id,
    :ref,
    :thread_ref,
    :workspace_ref
  ]

  @insert_required @fields --
                     [
                       :card_checked_at,
                       :card_fingerprint,
                       :card_ui_revision,
                       :last_error_code,
                       :last_error_detail,
                       :lease_expires_at,
                       :lease_owner,
                       :lease_ref,
                       :next_attempt_at
                     ]

  def insert(attributes) do
    %TaskCard{}
    |> cast(attributes, @fields)
    |> validate_required(@insert_required)
    |> validate_card()
  end

  def update(%TaskCard{} = card, attributes) do
    card
    |> cast(attributes, @fields -- [:id, :record_id, :episode_id, :ref])
    |> validate_card()
  end

  defp validate_card(changeset) do
    changeset
    |> validate_length(:ref, min: 1, max: 256)
    |> validate_length(:workspace_ref, min: 1, max: 256)
    |> validate_length(:channel_ref, min: 1, max: 256)
    |> validate_length(:thread_ref, min: 1, max: 1_024)
    |> validate_length(:message_ref, min: 1, max: 1_024)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_number(:card_ui_revision, greater_than_or_equal_to: 0)
    |> validate_format(:card_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> unique_constraint(:ref)
    |> unique_constraint(:record_id)
    |> unique_constraint(:episode_id)
    |> foreign_key_constraint(:record_id)
    |> foreign_key_constraint(:episode_id)
    |> check_constraint(:ref, name: :slack_task_card_valid)
  end
end
