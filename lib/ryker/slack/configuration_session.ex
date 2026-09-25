defmodule Ryker.Slack.ConfigurationSession do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "slack_configuration_sessions" do
    field(:workspace_ref, :string)
    field(:channel_ref, :string)
    field(:membership_generation, :integer)
    field(:start_event_ref, :string)
    field(:start_fingerprint, :string)
    field(:initiator_ref, :string)
    field(:step, Ecto.Enum, values: [:participation, :environment, :alerts, :audience, :confirm])
    field(:status, Ecto.Enum, values: [:asking, :confirming, :saved, :cancelled, :expired])
    field(:draft, Ryker.CanonicalJSON.Type)
    field(:revision, :integer)
    field(:root_message_ref, :string)
    field(:response_thread_ref, :string)
    field(:current_message_ref, :string)
    field(:expires_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
