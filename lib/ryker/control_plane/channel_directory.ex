defmodule Ryker.ControlPlane.ChannelDirectory do
  @moduledoc """
  The channel directory: every Slack channel any durable table mentions, with
  its effective participation and environment, membership, incident room,
  conversation count and whether it carries its own instructions. One
  channel's detail is `ChannelDetail`.
  """

  import Ecto.Query

  alias Ryker.ControlPlane.{Search, SlackNames}
  alias Ryker.Episodes.Episode
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.Slack.{ChannelConfiguration, ChannelMembership, IncidentRoom}

  @list_limit 100

  @doc """
  Every channel a durable table mentions, most recently active first.

  `"q"` narrows to channels whose name, id, workspace or environment contains
  the phrase; `"show" => "in_use"` keeps only the channels Ryker is in.
  """
  def list(params) when is_map(params) do
    configurations =
      Repo.all(
        from(configuration in ChannelConfiguration,
          order_by: [asc: configuration.workspace_ref, asc: configuration.channel_ref],
          limit: 500
        )
      )

    memberships =
      Repo.all(
        from(membership in ChannelMembership,
          order_by: [asc: membership.workspace_ref, asc: membership.channel_ref],
          limit: 500
        )
      )

    rooms = incident_rooms()
    episode_counts = slack_episode_counts()
    default = defaults()

    keys =
      (Enum.map(configurations, &{&1.workspace_ref, &1.channel_ref}) ++
         Enum.map(memberships, &{&1.workspace_ref, &1.channel_ref}) ++
         Map.keys(episode_counts) ++ Map.keys(rooms))
      |> Enum.uniq()

    configurations = Map.new(configurations, &{{&1.workspace_ref, &1.channel_ref}, &1})
    memberships = Map.new(memberships, &{{&1.workspace_ref, &1.channel_ref}, &1})

    keys
    |> Enum.map(fn key ->
      row(
        key,
        configurations[key],
        memberships[key],
        rooms[key],
        Map.get(episode_counts, key, %{episodes: 0, last_at: nil}),
        default
      )
    end)
    |> filter_in_use(params["show"])
    |> filter_channel_search(Search.term(params["q"]))
    |> Enum.sort_by(&{date_sort(&1.last_at), &1.workspace_ref, &1.channel_ref}, :desc)
    |> Enum.take(@list_limit)
    |> with_channel_instructions()
  end

  def list(_params), do: list(%{})

  defp row({workspace_ref, channel_ref}, configuration, membership, room, counts, default) do
    %{
      channel_ref: channel_ref,
      episodes: counts.episodes,
      incident_room: room,
      last_at: counts.last_at || updated_at(configuration) || updated_at(membership),
      workspace_ref: workspace_ref
    }
    |> Map.merge(membership_facts(membership))
    |> Map.merge(configuration_facts(configuration, room, default))
  end

  defp membership_facts(nil), do: %{external_shared: nil, membership: nil, private: nil}

  defp membership_facts(membership),
    do: %{
      external_shared: membership.external_shared,
      membership: membership.status,
      private: membership.private
    }

  # A channel that never chose follows the installation default, so the list
  # shows what Ryker actually does there, not a blank.
  defp configuration_facts(configuration, room, default) do
    Map.merge(
      participation_facts(configuration, default.participation),
      environment_facts(configuration, room, default)
    )
  end

  defp participation_facts(%{participation: chosen}, _default) when not is_nil(chosen),
    do: %{participation: chosen, participation_source: :channel}

  defp participation_facts(_configuration, default),
    do: %{participation: default, participation_source: :installation}

  # A channel with its own setting works in the environment it chose, or in
  # none; an incident room keeps what it was opened with; any other
  # conversation works in the default environment.
  defp environment_facts(nil, nil, default),
    do: environment(default.environment, :default, default.names)

  defp environment_facts(nil, _room, _default),
    do: %{environment_ref: nil, environment_name: nil, environment_source: :incident_room}

  defp environment_facts(configuration, _room, default),
    do: environment(configuration.environment_ref, :channel, default.names)

  defp environment(ref, source, names),
    do: %{
      environment_ref: ref,
      environment_name: ref && Map.get(names, ref, ref),
      environment_source: source
    }

  # The newest room per channel decides whether an incident is open there.
  defp incident_rooms do
    Repo.all(
      from(room in IncidentRoom,
        where: not is_nil(room.channel_ref),
        order_by: [desc: room.updated_at, desc: room.id],
        limit: 500,
        select: {{room.workspace_ref, room.channel_ref}, room.status, room.channel_state}
      )
    )
    |> Enum.reduce(%{}, fn {key, status, channel_state}, found ->
      Map.put_new(found, key, %{
        status: status,
        open: status != :closed and channel_state not in [:archived, :deleted]
      })
    end)
  end

  defp with_channel_instructions(items) do
    configured = Ryker.Instructions.configured_channels(items)

    Enum.map(
      items,
      &Map.put(
        &1,
        :custom_instructions,
        MapSet.member?(configured, "slack:#{&1.workspace_ref}:#{&1.channel_ref}")
      )
    )
  end

  defp defaults do
    environments =
      Repo.all(
        from(environment in Settings.Environment,
          select: {environment.ref, environment.display_name, environment.is_default}
        )
      )

    %{
      environment:
        Enum.find_value(environments, fn {ref, _name, default} -> if default, do: ref end),
      names: Map.new(environments, fn {ref, name, _default} -> {ref, name} end),
      participation:
        Repo.one(from(slack in Settings.Slack, select: slack.default_participation, limit: 1)) ||
          :mentions
    }
  end

  defp slack_episode_counts do
    Repo.all(
      from(episode in Episode,
        where:
          episode.destination_transport == "slack" and
            like(episode.destination_conversation_ref, "slack:%"),
        group_by: episode.destination_conversation_ref,
        order_by: [desc: max(episode.updated_at)],
        limit: 500,
        select: %{
          conversation_ref: episode.destination_conversation_ref,
          episodes: count(episode.id),
          last_at: max(episode.updated_at)
        }
      )
    )
    |> Enum.reduce(%{}, fn row, found ->
      case String.split(row.conversation_ref, ":", parts: 3) do
        ["slack", workspace_ref, channel_ref] ->
          Map.put(found, {workspace_ref, channel_ref}, Map.drop(row, [:conversation_ref]))

        _invalid ->
          found
      end
    end)
  end

  defp filter_in_use(rows, "in_use"), do: Enum.filter(rows, &(&1.membership == :joined))
  defp filter_in_use(rows, _all), do: rows

  defp filter_channel_search(rows, nil), do: rows

  # People search for the names they see ("#infra"), not Slack's ids; the
  # ids and the environment still match for anyone pasting one.
  defp filter_channel_search(rows, search) do
    search = String.downcase(search)

    Enum.filter(rows, fn row ->
      Enum.any?(
        [
          SlackNames.name(row.workspace_ref, row.channel_ref),
          SlackNames.name(row.workspace_ref, row.workspace_ref),
          row.workspace_ref,
          row.channel_ref,
          row.environment_name,
          row.environment_ref
        ],
        &(is_binary(&1) and String.contains?(String.downcase(&1), search))
      )
    end)
  end

  defp updated_at(nil), do: nil
  defp updated_at(record), do: record.updated_at

  defp date_sort(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)
  defp date_sort(_missing), do: 0
end
