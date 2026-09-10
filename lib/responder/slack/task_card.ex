defmodule Responder.Slack.TaskCard do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "slack_task_cards" do
    belongs_to(:record, Responder.State.Record)
    belongs_to(:episode, Responder.Episodes.Episode)
    field(:ref, :string)
    field(:workspace_ref, :string)
    field(:channel_ref, :string)
    field(:thread_ref, :string)
    field(:message_ref, :string)
    field(:card_fingerprint, :string)
    field(:card_ui_revision, :integer, default: 0)
    field(:card_checked_at, :utc_datetime_usec)
    field(:attempt_count, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:lease_owner, :string)
    field(:lease_ref, :binary_id)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:last_error_code, :string)
    field(:last_error_detail, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          record_id: Ecto.UUID.t() | nil,
          episode_id: Ecto.UUID.t() | nil,
          ref: String.t() | nil,
          workspace_ref: String.t() | nil,
          channel_ref: String.t() | nil,
          thread_ref: String.t() | nil,
          message_ref: String.t() | nil,
          card_fingerprint: String.t() | nil,
          card_ui_revision: non_neg_integer(),
          card_checked_at: DateTime.t() | nil,
          attempt_count: non_neg_integer(),
          next_attempt_at: DateTime.t() | nil,
          lease_owner: String.t() | nil,
          lease_ref: Ecto.UUID.t() | nil,
          lease_expires_at: DateTime.t() | nil,
          last_error_code: String.t() | nil,
          last_error_detail: String.t() | nil
        }
end
