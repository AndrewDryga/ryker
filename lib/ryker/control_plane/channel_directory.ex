defmodule Ryker.ControlPlane.ChannelDirectory do
  @moduledoc """
  The channel directory: every Slack channel any durable table mentions, with
  its configuration, membership, incident room, episode count and whether it
  carries its own instructions. One channel's detail is `ChannelDetail`.
  """

  import Ecto.Query

  alias Ryker.ControlPlane.Search
  alias Ryker.Episodes.Episode
  alias Ryker.Repo
  alias Ryker.Slack.{ChannelConfiguration, ChannelMembership, IncidentRoom}

  @list_limit 100

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

    rooms =
      Repo.all(
        from(room in IncidentRoom,
          where: not is_nil(room.channel_ref),
          order_by: [desc: room.updated_at],
          limit: 500,
          select: {room.workspace_ref, room.channel_ref}
        )
      )
      |> MapSet.new()

    episode_counts = slack_episode_counts()

    keys =
      (Enum.map(configurations, &{&1.workspace_ref, &1.channel_ref}) ++
         Enum.map(memberships, &{&1.workspace_ref, &1.channel_ref}) ++
         Map.keys(episode_counts) ++ MapSet.to_list(rooms))
      |> Enum.uniq()

    configurations = Map.new(configurations, &{{&1.workspace_ref, &1.channel_ref}, &1})
    memberships = Map.new(memberships, &{{&1.workspace_ref, &1.channel_ref}, &1})

    keys
    |> Enum.map(fn {workspace_ref, channel_ref} = key ->
      configuration = configurations[key]
      membership = memberships[key]
      counts = Map.get(episode_counts, key, %{episodes: 0, last_at: nil})

      %{
        channel_ref: channel_ref,
        episodes: counts.episodes,
        incident_room: MapSet.member?(rooms, key),
        last_at: counts.last_at || updated_at(configuration) || updated_at(membership),
        membership: membership && membership.status,
        participation: configuration && configuration.participation,
        private: membership && membership.private,
        repository_ref: configuration && configuration.repository_ref,
        workspace_ref: workspace_ref
      }
    end)
    |> filter_channel_search(Search.term(params["q"]))
    |> Enum.sort_by(&{date_sort(&1.last_at), &1.workspace_ref, &1.channel_ref}, :desc)
    |> Enum.take(@list_limit)
    |> with_channel_instructions()
  end

  def list(_params), do: list(%{})

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

  defp filter_channel_search(rows, nil), do: rows

  defp filter_channel_search(rows, search) do
    search = String.downcase(search)

    Enum.filter(rows, fn row ->
      Enum.any?(
        [row.workspace_ref, row.channel_ref, row.repository_ref, row.participation],
        &(is_binary(&1) and String.contains?(String.downcase(&1), search))
      )
    end)
  end

  defp updated_at(nil), do: nil
  defp updated_at(record), do: record.updated_at

  defp date_sort(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)
  defp date_sort(_missing), do: 0
end
