defmodule Ryker.Slack.ChannelSettingsTest do
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.Repo
  alias Ryker.Settings

  alias Ryker.Slack.{
    ChannelConfiguration,
    ChannelConfigurationChangeset,
    ChannelSettingAudit,
    ChannelSettings
  }

  @now ~U[2026-08-28 12:00:00.000000Z]
  @workspace "T79ED658E769C"
  @conversation "slack:T79ED658E769C:C456"
  @operator "slack:user:U123"

  setup do
    {:ok, _} = Settings.initialize("control-plane:local")
    {:ok, _} = Settings.put_repository(%{ref: "infrastructure"}, 1, "control-plane:local")

    {:ok, saved} =
      Settings.save_slack(
        %{
          enabled: true,
          workspace_ref: @workspace,
          bot_ref: "A0123456789",
          bot_user_ref: "U0123456789",
          default_repository_ref: "infrastructure",
          operators: ["U123"]
        },
        2,
        "control-plane:local"
      )

    %{settings: saved}
  end

  test "a channel with no saved participation inherits the installation default" do
    assert ChannelSettings.effective(@workspace, @conversation, :mentions) == %{
             proactive: %{source: :installation, value: false},
             shadow: %{source: :installation, value: false}
           }

    assert {:ok, _} = Settings.save_default_participation(:proactive, @operator)

    assert ChannelSettings.effective(@workspace, @conversation, :proactive) == %{
             proactive: %{source: :installation, value: true},
             shadow: %{source: :installation, value: false}
           }
  end

  test "an explicit channel value wins over the installation default and inherit restores it" do
    configuration!(nil)

    assert {:ok, channel} =
             ChannelSettings.change(change(:channel, :proactive, :on, "event:channel-on"))

    assert channel.status == :updated
    assert channel.effective.proactive == %{source: :channel, value: true}

    # The installation default moving must not disturb an explicit channel value.
    assert {:ok, _} = Settings.save_default_participation(:shadow, @operator)

    assert ChannelSettings.effective(@workspace, @conversation, :shadow).proactive ==
             %{source: :channel, value: true}

    assert {:ok, inherited} =
             ChannelSettings.change(change(:channel, :proactive, :inherit, "event:inherit"))

    assert inherited.effective == %{
             proactive: %{source: :installation, value: false},
             shadow: %{source: :installation, value: true}
           }

    assert Repo.one!(ChannelConfiguration).participation == nil
    assert Repo.aggregate(ChannelSettingAudit, :count) == 2
  end

  test "a workspace-scoped command edits the installation default through the settings store" do
    configuration!(nil)

    assert {:ok, workspace} =
             ChannelSettings.change(change(:workspace, :shadow, :on, "event:workspace-shadow"))

    assert workspace.effective.shadow == %{source: :installation, value: true}
    assert {:ok, current} = Settings.fetch()
    assert current.slack.default_participation == :shadow

    # A Slack actor who is not a saved operator cannot move the installation default.
    intruder = %{change(:workspace, :shadow, :off, "event:intruder") | actor_ref: "U999"}
    assert ChannelSettings.change(intruder) == {:error, :settings_forbidden}

    assert Settings.fetch() |> elem(1) |> Map.fetch!(:slack) |> Map.fetch!(:default_participation) ==
             :shadow
  end

  test "an exact command retry is idempotent and a crossed event id conflicts" do
    configuration!(nil)
    request = change(:channel, :shadow, :on, "event:shadow")

    assert {:ok, first} = ChannelSettings.change(request)
    assert first.status == :updated
    assert {:ok, duplicate} = ChannelSettings.change(request)
    assert duplicate.status == :duplicate

    assert ChannelSettings.change(%{request | value: :off}) ==
             {:error, :channel_setting_event_conflict}

    assert Repo.aggregate(ChannelSettingAudit, :count) == 1
    assert Repo.one!(ChannelConfiguration).participation == :shadow

    audit = Repo.one!(from(event in ChannelSettingAudit))
    assert audit.actor_ref == "U123"
    assert audit.outcome == :updated
    assert audit.detail == %{"scope" => "channel", "setting" => "shadow", "value" => "on"}
  end

  test "a saved shadow participation reports observation without proactive replies" do
    configuration!(:shadow)

    assert ChannelSettings.effective(@workspace, @conversation, :mentions) == %{
             proactive: %{source: :channel, value: false},
             shadow: %{source: :channel, value: true}
           }
  end

  test "invalid identity and an unknown default fail closed without writing" do
    configuration!(nil)

    assert ChannelSettings.change(%{change(:channel, :shadow, :on, "event:bad") | actor_ref: ""}) ==
             {:error, {:invalid_channel_setting, :actor_ref}}

    assert ChannelSettings.effective(@workspace, @conversation, :everything) ==
             {:error, {:invalid_channel_setting, :default_participation}}

    assert Repo.aggregate(ChannelSettingAudit, :count) == 0
  end

  defp configuration!(participation) do
    %{
      actor_ref: if(participation, do: "U123"),
      alert_policy: :reply,
      channel_ref: "C456",
      id: Ecto.UUID.generate(),
      invite_user_group_refs: [],
      invite_user_refs: [],
      participation: participation,
      repository_ref: "infrastructure",
      revision: 1,
      saved_at: @now,
      workspace_ref: @workspace
    }
    |> ChannelConfigurationChangeset.configuration()
    |> Repo.insert!()
  end

  defp change(scope, setting, value, event_ref) do
    %{
      actor_ref: "U123",
      conversation_ref: @conversation,
      event_ref: event_ref,
      occurred_at: @now,
      scope: scope,
      setting: setting,
      value: value,
      workspace_ref: @workspace
    }
  end
end
