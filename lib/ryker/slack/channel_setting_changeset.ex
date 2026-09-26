defmodule Ryker.Slack.ChannelSettingChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Ryker.Slack.ChannelSettingAudit

  @audit_fields [
    :actor_ref,
    :conversation_ref,
    :detail,
    :event_ref,
    :id,
    :occurred_at,
    :outcome,
    :request_fingerprint,
    :workspace_ref
  ]

  def insert_audit(attributes) do
    %ChannelSettingAudit{}
    |> cast(attributes, @audit_fields)
    |> validate_required(@audit_fields)
    |> unique_constraint(:event_ref)
    |> check_constraint(:event_ref, name: :slack_channel_setting_audit_valid)
  end
end
