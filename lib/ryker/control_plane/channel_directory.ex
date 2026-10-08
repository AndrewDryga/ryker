defmodule Ryker.ControlPlane.ChannelDirectory do
  @moduledoc """
  The channel directory: every Slack channel any durable table mentions, with
  its effective participation and environment, membership, incident room,
  conversation count and whether it carries its own instructions. One
  channel's detail is `ChannelDetail`.
  """
  alias Ryker.ControlPlane.{ChannelDirectory, ChannelsPage, PagedRelation, Search}
  alias Ryker.ConversationRef
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.Slack

  @doc """
  One page of `rows/1` under `params["page"]`, with how many channels match.

  The directory read 500 channels by name from each table, then kept the 100
  most recently active and said nothing of the rest (2026-10-04 review).
  """
  @spec list(map()) :: PagedRelation.t()
  def list(params) when is_map(params) do
    page = params |> rows() |> PagedRelation.slice("page", params)
    %{page | items: with_channel_instructions(page.items)}
  end

  def list(_params), do: list(%{})

  @doc """
  Every channel a durable table mentions, most recently active first.

  `"q"` narrows to channels whose name, id, workspace or environment contains
  the phrase; `"show" => "in_use"` keeps only the channels Ryker is in.
  """
  @spec rows(map()) :: [map()]
  def rows(params) when is_map(params) do
    configurations = Repo.all(Slack.ChannelConfiguration.Query.all())
    memberships = Repo.all(Slack.ChannelMembership.Query.all())

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
  end

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
    ChannelDirectory.Query.latest_rooms()
    |> Repo.all()
    |> Map.new(fn {key, status, channel_state, channel_name} ->
      {key,
       %{
         channel_name: channel_name,
         status: status,
         open: status != :closed and channel_state not in [:archived, :deleted]
       }}
    end)
  end

  defp with_channel_instructions(items) do
    configured = Ryker.Instructions.configured_channels(items)

    Enum.map(
      items,
      &Map.put(
        &1,
        :custom_instructions,
        MapSet.member?(configured, ConversationRef.slack(&1.workspace_ref, &1.channel_ref))
      )
    )
  end

  defp defaults do
    environments = Repo.all(Settings.Environment.Query.select_names())

    %{
      environment:
        Enum.find_value(environments, fn {ref, _name, default} -> if default, do: ref end),
      names: Map.new(environments, fn {ref, name, _default} -> {ref, name} end),
      participation: default_participation()
    }
  end

  # How a channel takes part unless set otherwise: the installation's choice.
  defp default_participation do
    case Repo.fetch(Settings.Slack.Query.select_default_participation()) do
      {:ok, {_workspace_ref, participation}} when not is_nil(participation) -> participation
      _unset -> :mentions
    end
  end

  defp slack_episode_counts do
    ChannelDirectory.Query.episode_counts()
    |> Repo.all()
    |> Enum.reduce(%{}, fn row, found ->
      case ConversationRef.parse_slack(row.conversation_ref) do
        {:ok, workspace_ref, channel_ref} ->
          counts = Map.drop(row, [:conversation_ref])
          Map.put(found, {workspace_ref, channel_ref}, counts)

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
          ChannelsPage.channel_name(row.workspace_ref, row.channel_ref, row.incident_room),
          Slack.Names.name(row.workspace_ref, row.workspace_ref),
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
