defmodule Responder.Slack.Inbox.Entry do
  @moduledoc """
  One immutable Slack input plus its eventual admission decision.

  The input columns never change. Admission fills the decision columns and
  optional episode link exactly once in a later transaction.
  """

  use Ecto.Schema

  alias Responder.CanonicalJSON.Type, as: CanonicalJSONType
  alias Responder.Episodes.Episode

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "slack_inbox_entries" do
    field(:dedupe_key, :string)
    field(:event_fingerprint, :string)
    field(:workspace_ref, :string)
    field(:channel_ref, :string)
    field(:event_ref, :string)
    field(:event_kind, Ecto.Enum, values: [:message, :edit, :delete])
    field(:message_ref, :string)
    field(:thread_ref, :string)
    field(:actor_kind, Ecto.Enum, values: [:user, :app, :bot])
    field(:actor_ref, :string)
    field(:revision, :integer)
    field(:occurred_at, :utc_datetime_usec)
    field(:content, CanonicalJSONType)
    field(:status, Ecto.Enum, values: [:pending, :decided], default: :pending)
    field(:decision_ref, :string)
    field(:decision_fingerprint, :string)

    field(:decision_action, Ecto.Enum,
      values: [:start_episode, :continue_episode, :reply, :react, :ignore]
    )

    field(:decision_document, CanonicalJSONType)
    belongs_to(:episode, Episode)

    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
