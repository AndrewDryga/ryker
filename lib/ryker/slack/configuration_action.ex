defmodule Ryker.Slack.ConfigurationAction do
  @moduledoc false
  use Ryker, :schema

  schema "slack_configuration_actions" do
    belongs_to(:session, Ryker.Slack.ConfigurationSession)
    field(:event_ref, :string)
    field(:event_fingerprint, :string)
    field(:actor_ref, :string)
    field(:action, :string)
    field(:outcome, :string)
    field(:session_revision, :integer)
    timestamps(updated_at: false)
  end
end
