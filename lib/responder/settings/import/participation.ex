defmodule Responder.Settings.Import.Participation do
  @moduledoc """
  Folds the four retired Slack participation layers into the consolidated model.

  The retired resolution was, per channel and per boolean: a channel-scoped
  override beat the confirmed channel setup, which beat a workspace-scoped
  override, which beat the deployment `slack.watch_channels` list. The saved
  model is one installation default plus, on a channel that actually chose, one
  explicit value; a channel that never chose stores nothing, so moving the
  default later reaches it and disturbs none that did choose.

  `resolve/1` reproduces the old effective value for every channel any of those
  layers named and reports it, without writing. `fold!/2` applies exactly that
  result. Nothing is discarded silently: a retained override this installation
  cannot own is a refusal from `refusals/1`, never a dropped row.
  """

  import Ecto.Query

  alias Responder.Repo

  alias Responder.Slack.{
    ChannelConfiguration,
    ChannelConfigurationChangeset,
    ChannelSettingOverride
  }

  @participation [:mentions, :proactive, :shadow]
  @settings [:proactive, :shadow]

  @doc "The installation default and the per-channel value the old layers produce."
  @spec resolve(map()) :: %{
          channels: [map()],
          installation_default: atom(),
          workspace_ref: String.t() | nil
        }
  def resolve(values) do
    slack = Map.get(values, :slack)
    overrides = overrides()
    configurations = configurations()
    watched = MapSet.new((slack && slack.watch_channels) || [])
    workspace = Enum.filter(overrides, &(&1.scope_kind == :workspace))
    default = collapse(effective(nil, [], workspace, false))

    channels =
      configurations
      |> Enum.map(& &1.channel_ref)
      |> Enum.concat(Enum.map(overrides, &channel_of/1))
      |> Enum.concat(MapSet.to_list(watched))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&channel(&1, configurations, overrides, workspace, watched, default))

    %{
      channels: channels,
      installation_default: default,
      workspace_ref: slack && slack.identity.workspace_ref
    }
  end

  defp channel(channel_ref, configurations, overrides, workspace, watched, default) do
    configuration = Enum.find(configurations, &(&1.channel_ref == channel_ref))
    channel = Enum.filter(overrides, &(channel_of(&1) == channel_ref))
    watched? = channel_ref in watched
    resolved = collapse(effective(configuration, channel, workspace, watched?))

    # A channel that chose for itself keeps an explicit value even when it equals
    # today's default, so a later change of the default cannot move a decision an
    # operator already made.
    chosen? =
      channel != [] or (configuration != nil and configuration.participation in @participation)

    target = if chosen? or resolved != default, do: resolved

    %{
      action: action(configuration, target),
      channel_ref: channel_ref,
      from: source_of(channel, configuration, watched?),
      participation: target
    }
  end

  defp effective(configuration, channel, workspace, watched?) do
    Map.new(@settings, fn setting ->
      override = Enum.find(channel, &(&1.setting == setting))
      workspace_override = Enum.find(workspace, &(&1.setting == setting))

      value =
        cond do
          override -> override.value
          configuration -> configuration.participation == setting
          workspace_override -> workspace_override.value
          setting == :proactive -> watched?
          true -> false
        end

      {setting, value}
    end)
  end

  defp collapse(%{shadow: true}), do: :shadow
  defp collapse(%{proactive: true}), do: :proactive
  defp collapse(_neither), do: :mentions

  defp action(nil, nil), do: :unchanged
  defp action(nil, _target), do: :create
  defp action(%ChannelConfiguration{participation: current}, current), do: :unchanged
  defp action(%ChannelConfiguration{}, _target), do: :update

  defp source_of([_override | _rest], _configuration, _watched?), do: "channel override"

  defp source_of([], %ChannelConfiguration{participation: chosen}, _watched?)
       when chosen in @participation,
       do: "confirmed channel setup"

  defp source_of([], _configuration, true), do: "slack.watch_channels"
  defp source_of([], _configuration, false), do: "workspace override or deployment default"

  defp channel_of(%ChannelSettingOverride{scope_kind: :channel, scope_ref: ref}),
    do: ref |> String.split(":", parts: 3) |> List.last()

  defp channel_of(%ChannelSettingOverride{}), do: nil

  @doc "Retained channel state this document cannot own, named rather than dropped."
  @spec refusals(map()) :: [%{path: String.t(), reason: atom()}]
  def refusals(values) do
    workspace_ref = get_in(values, [:slack, :identity, :workspace_ref])
    overrides = overrides()

    refuse(
      overrides != [] and is_nil(workspace_ref),
      "slack",
      :is_required_to_fold_retained_channel_overrides
    ) ++
      Enum.flat_map(overrides, &override_refusals(&1, workspace_ref)) ++
      Enum.flat_map(configurations(), fn configuration ->
        refuse(
          workspace_ref != nil and configuration.workspace_ref != workspace_ref,
          "slack_channel_configurations.#{configuration.channel_ref}",
          :belongs_to_another_workspace
        )
      end)
  end

  defp override_refusals(override, workspace_ref) do
    path = "slack_channel_setting_overrides.#{override.id}"

    refuse(
      workspace_ref != nil and override.workspace_ref != workspace_ref,
      path,
      :belongs_to_another_workspace
    ) ++
      refuse(
        override.scope_kind == :channel and not channel_scoped?(override),
        path,
        :does_not_name_a_channel_of_its_workspace
      )
  end

  defp channel_scoped?(override) do
    case String.split(override.scope_ref, ":", parts: 3) do
      ["slack", workspace, channel] -> workspace == override.workspace_ref and channel != ""
      _other -> false
    end
  end

  @doc """
  Writes the resolved result. A channel that inherits keeps no saved value.

  A watched channel with no configuration row at all gets one, because the list
  that used to carry its ambient participation is gone; it is created with the
  same shape a channel join creates, without a human actor.
  """
  @spec fold!(map(), map()) :: :ok
  def fold!(values, participation) do
    repository_ref = get_in(values, [:slack, :default_repository])
    now = DateTime.utc_now()

    Enum.each(participation.channels, fn channel ->
      write!(channel, participation.workspace_ref, repository_ref, now)
    end)
  end

  defp write!(%{action: :unchanged}, _workspace_ref, _repository_ref, _now), do: :ok

  defp write!(%{action: :update} = channel, workspace_ref, _repository_ref, now) do
    configuration =
      Repo.get_by!(ChannelConfiguration,
        workspace_ref: workspace_ref,
        channel_ref: channel.channel_ref
      )

    configuration
    |> ChannelConfigurationChangeset.configuration(%{
      participation: channel.participation,
      revision: configuration.revision + 1,
      saved_at: now
    })
    |> Repo.update!()

    :ok
  end

  defp write!(%{action: :create} = channel, workspace_ref, repository_ref, now) do
    %{
      actor_ref: nil,
      alert_policy: :reply,
      channel_ref: channel.channel_ref,
      id: Ecto.UUID.generate(),
      invite_user_group_refs: [],
      invite_user_refs: [],
      participation: channel.participation,
      repository_ref: repository_ref,
      revision: 1,
      saved_at: now,
      welcome_message_ref: nil,
      workspace_ref: workspace_ref
    }
    |> ChannelConfigurationChangeset.configuration()
    |> Repo.insert!()

    :ok
  end

  defp overrides, do: Repo.all(from(override in ChannelSettingOverride, order_by: override.id))

  defp configurations,
    do: Repo.all(from(item in ChannelConfiguration, order_by: item.channel_ref))

  defp refuse(true, path, reason), do: [%{path: path, reason: reason}]
  defp refuse(_false, _path, _reason), do: []
end
