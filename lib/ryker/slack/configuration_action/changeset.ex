defmodule Ryker.Slack.ConfigurationAction.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.Slack.ConfigurationAction

  @fields [
    :action,
    :actor_ref,
    :event_fingerprint,
    :event_ref,
    :id,
    :outcome,
    :session_id,
    :session_revision
  ]

  def insert(attributes) do
    %ConfigurationAction{}
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> unique_constraint(:event_ref)
    |> check_constraint(:event_ref, name: :slack_configuration_action_valid)
  end
end
