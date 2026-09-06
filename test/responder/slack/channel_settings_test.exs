defmodule Responder.Slack.ChannelSettingsTest do
  use Responder.DataCase, async: true

  import Ecto.Query

  alias Responder.Repo

  alias Responder.Slack.{
    ChannelConfigurationChangeset,
    ChannelSettingAudit,
    ChannelSettingOverride,
    ChannelSettings
  }

  @now ~U[2026-08-28 12:00:00.000000Z]

  test "channel and workspace overrides have explicit precedence and inherit deletes an override" do
    defaults = %{proactive: false, shadow: false}

    assert ChannelSettings.effective("T79ED658E769C", "slack:T79ED658E769C:C456", defaults) == %{
             proactive: %{source: :deployment, value: false},
             shadow: %{source: :deployment, value: false}
           }

    assert {:ok, channel} =
             ChannelSettings.change(change(:channel, :proactive, :on, "event:channel-on"))

    assert channel.status == :updated

    assert channel.effective.proactive == %{source: :channel, value: true}

    assert {:ok, workspace} =
             ChannelSettings.change(change(:workspace, :proactive, :off, "event:workspace-off"))

    assert workspace.effective.proactive == %{source: :channel, value: true}

    assert {:ok, inherited} =
             ChannelSettings.change(change(:channel, :proactive, :inherit, "event:inherit"))

    assert inherited.effective.proactive == %{source: :workspace, value: false}
    assert Repo.aggregate(ChannelSettingOverride, :count) == 1
    assert Repo.aggregate(ChannelSettingAudit, :count) == 3
  end

  test "an exact command retry is idempotent and a crossed event id conflicts" do
    request = change(:channel, :shadow, :on, "event:shadow")

    assert {:ok, first} = ChannelSettings.change(request)
    assert first.status == :updated
    assert {:ok, duplicate} = ChannelSettings.change(request)
    assert duplicate.status == :duplicate

    assert ChannelSettings.change(%{request | value: :off}) ==
             {:error, :channel_setting_event_conflict}

    assert Repo.aggregate(ChannelSettingOverride, :count) == 1
    assert Repo.aggregate(ChannelSettingAudit, :count) == 1

    audit = Repo.one!(from(event in ChannelSettingAudit))
    assert audit.actor_ref == "U123"
    assert audit.outcome == :updated

    assert audit.detail == %{
             "scope" => "channel",
             "setting" => "shadow",
             "value" => "on"
           }
  end

  test "emergency channel overrides win over confirmed setup then workspace and deployment" do
    %{
      actor_ref: "U123",
      alert_policy: :reply,
      channel_ref: "C456",
      id: Ecto.UUID.generate(),
      invite_user_group_refs: [],
      invite_user_refs: [],
      participation: :shadow,
      repository_ref: "infrastructure",
      revision: 1,
      saved_at: @now,
      workspace_ref: "T79ED658E769C"
    }
    |> ChannelConfigurationChangeset.configuration()
    |> Repo.insert!()

    assert {:ok, _workspace} =
             ChannelSettings.change(change(:workspace, :shadow, :off, "event:workspace-shadow"))

    assert ChannelSettings.effective("T79ED658E769C", "slack:T79ED658E769C:C456", %{
             proactive: true,
             shadow: false
           }).shadow == %{source: :configuration, value: true}

    assert {:ok, _channel} =
             ChannelSettings.change(change(:channel, :shadow, :off, "event:channel-shadow"))

    assert ChannelSettings.effective("T79ED658E769C", "slack:T79ED658E769C:C456", %{
             proactive: true,
             shadow: false
           }).shadow == %{source: :channel, value: false}
  end

  test "invalid identity and malformed defaults fail closed" do
    assert ChannelSettings.change(%{change(:channel, :shadow, :on, "event:bad") | actor_ref: ""}) ==
             {:error, {:invalid_channel_setting, :actor_ref}}

    assert ChannelSettings.effective("T79ED658E769C", "slack:T79ED658E769C:C456", %{
             proactive: true
           }) ==
             {:error, {:invalid_channel_setting, :defaults}}
  end

  defp change(scope, setting, value, event_ref) do
    %{
      actor_ref: "U123",
      conversation_ref: "slack:T79ED658E769C:C456",
      event_ref: event_ref,
      occurred_at: @now,
      scope: scope,
      setting: setting,
      value: value,
      workspace_ref: "T79ED658E769C"
    }
  end
end
