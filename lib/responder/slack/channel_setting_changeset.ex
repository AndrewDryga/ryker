defmodule Responder.Slack.ChannelSettingChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Responder.Slack.{ChannelSettingAudit, ChannelSettingOverride}

  @override_fields [
    :actor_ref,
    :event_ref,
    :id,
    :revision,
    :scope_kind,
    :scope_ref,
    :setting,
    :value,
    :workspace_ref
  ]

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

  def insert_override(attributes) do
    %ChannelSettingOverride{}
    |> cast(attributes, @override_fields)
    |> validate_required(@override_fields)
    |> unique_constraint(:setting, name: :slack_channel_setting_identity)
    |> check_constraint(:setting, name: :slack_channel_setting_override_valid)
  end

  def update_override(%ChannelSettingOverride{} = setting, attributes) do
    setting
    |> cast(attributes, [:actor_ref, :event_ref, :revision, :value])
    |> validate_required([:actor_ref, :event_ref, :revision, :value])
    |> check_constraint(:setting, name: :slack_channel_setting_override_valid)
  end

  def insert_audit(attributes) do
    %ChannelSettingAudit{}
    |> cast(attributes, @audit_fields)
    |> validate_required(@audit_fields)
    |> unique_constraint(:event_ref)
    |> check_constraint(:event_ref, name: :slack_channel_setting_audit_valid)
  end
end
