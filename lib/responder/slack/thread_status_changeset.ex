defmodule Responder.Slack.ThreadStatusChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Responder.Slack.ThreadStatus

  @fields [
    :attempt_count,
    :channel_ref,
    :delivered_at,
    :delivered_generation,
    :desired_text,
    :generation,
    :id,
    :last_error_code,
    :last_error_detail,
    :lease_expires_at,
    :lease_owner,
    :lease_ref,
    :next_attempt_at,
    :phase,
    :origin_kind,
    :origin_id,
    :status,
    :thread_ref,
    :workspace_ref
  ]

  def insert(attributes) do
    %ThreadStatus{}
    |> cast(attributes, @fields, empty_values: [])
    |> validate_required([:id, :workspace_ref, :channel_ref, :thread_ref, :phase, :desired_text])
    |> validate_status()
  end

  def update(%ThreadStatus{} = status, attributes) do
    status
    |> cast(attributes, @fields -- [:id, :workspace_ref, :channel_ref, :thread_ref],
      empty_values: []
    )
    |> validate_status()
  end

  defp validate_status(changeset) do
    changeset
    |> validate_length(:workspace_ref, min: 1, max: 256)
    |> validate_length(:channel_ref, min: 1, max: 256)
    |> validate_format(:thread_ref, ~r/\A[0-9]{10,}\.[0-9]{1,6}\z/)
    |> validate_length(:desired_text, max: 100, count: :bytes)
    |> validate_number(:generation, greater_than_or_equal_to: 1)
    |> validate_number(:delivered_generation, greater_than_or_equal_to: 0)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> unique_constraint([:workspace_ref, :channel_ref, :thread_ref],
      name: :slack_thread_status_identity_unique
    )
    |> check_constraint(:status, name: :slack_thread_status_valid)
  end
end
