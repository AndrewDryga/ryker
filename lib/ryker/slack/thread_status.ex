defmodule Ryker.Slack.ThreadStatus do
  @moduledoc false
  use Ryker, :schema

  schema "slack_thread_statuses" do
    field(:workspace_ref, :string)
    field(:channel_ref, :string)
    field(:thread_ref, :string)
    field(:origin_kind, :string)
    field(:origin_id, :binary_id)

    field(:phase, Ecto.Enum,
      values: [
        :queued,
        :admitting,
        :admission_retry,
        :working,
        :delivery,
        :waiting_for_input,
        :waiting_for_event,
        :blocked,
        :clear
      ]
    )

    field(:desired_text, :string)
    field(:generation, :integer, default: 1)
    field(:delivered_generation, :integer, default: 0)
    # A blocked status is never claimed again until a person rearms it or a
    # newer desired status replaces it.
    field(:status, Ecto.Enum, values: [:pending, :delivered, :blocked], default: :pending)
    field(:attempt_count, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:lease_owner, :string)
    field(:lease_ref, :binary_id)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:last_error_code, :string)
    field(:last_error_detail, :string)
    field(:delivered_at, :utc_datetime_usec)
    timestamps()
  end

  @type t :: %__MODULE__{}
end
