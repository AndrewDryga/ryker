defmodule Responder.ControlPlane.ChannelDetail do
  @moduledoc """
  Bounded, read-only overview of one Slack channel.

  Every field is selected explicitly and every related collection is read
  through `PagedRelation` with an exact total. Loading it never calls Slack, a
  model, Git, Coop or Emisar, never accounts a recall, and never rewrites a
  stored status: expiry and visibility are applied at read time instead.
  """

  import Ecto.Query

  alias Responder.ControlPlane.{ChannelScope, PagedRelation}
  alias Responder.Episodes.Episode
  alias Responder.Repo
  alias Responder.Slack.{ChannelConfiguration, ChannelMembership, ChannelSettings, IncidentRoom}
  alias Responder.State.{ConversationSummary, Schedule}

  @type collection :: PagedRelation.t()

  # Every repeating relation owns one namespaced page parameter, so paging one
  # section can never reset another. Anything else in the query string is
  # dropped before it reaches a query.
  @page_keys ~w(episode_page schedule_page summary_page)

  @doc "The query parameters the channel route accepts."
  @spec query_keys() :: [String.t()]
  def query_keys, do: @page_keys

  @doc """
  Projects `/channels/:workspace/:channel` for `params`.

  Returns `:not_found` when nothing durable mentions the channel and
  `{:error, :unavailable}` when the database cannot answer, so a broken read is
  never rendered as an empty channel.
  """
  @spec fetch(term(), term(), term()) :: {:ok, map()} | :not_found | {:error, :unavailable}
  def fetch(workspace_ref, channel_ref, params) do
    params = if is_map(params), do: params, else: %{}

    case ChannelScope.new(workspace_ref, channel_ref) do
      {:ok, scope} -> project(scope, params)
      :error -> :not_found
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] -> {:error, :unavailable}
  end

  defp project(scope, params) do
    configuration = configuration(scope)
    membership = membership(scope)
    incident_room = incident_room(scope)
    repository = repository(configuration, incident_room)
    scope = ChannelScope.with_repository(scope, repository && repository.ref)
    episodes = episodes(scope, params)

    if is_nil(configuration) and is_nil(membership) and is_nil(incident_room) and
         episodes.total == 0 do
      :not_found
    else
      relations = [episodes, schedules(scope, params), summaries(scope, params)]

      {:ok,
       %{
         scope: scope,
         params: link_params(relations),
         channel: %{
           kind: kind(scope, incident_room),
           membership: membership,
           configuration: configuration,
           incident_room: incident_room,
           repository: repository
         },
         participation: participation(scope, configuration),
         episodes: episodes,
         schedules: Enum.at(relations, 1),
         summaries: Enum.at(relations, 2)
       }}
    end
  end

  # The query string that reproduces this view: every section's resolved page,
  # so a link from one pager carries the others exactly where they are. Page
  # one is the default and stays out of the URL.
  defp link_params(relations) do
    for %{key: key, page: page} <- relations, page > 1, into: %{} do
      {key, Integer.to_string(page)}
    end
  end

  defp configuration(scope) do
    Repo.one(
      from(configuration in ChannelConfiguration,
        where:
          configuration.workspace_ref == ^scope.workspace_ref and
            configuration.channel_ref == ^scope.channel_ref,
        limit: 1,
        select: %{
          actor_ref: configuration.actor_ref,
          alert_policy: configuration.alert_policy,
          invite_user_group_refs: configuration.invite_user_group_refs,
          invite_user_refs: configuration.invite_user_refs,
          participation: configuration.participation,
          repository_ref: configuration.repository_ref,
          revision: configuration.revision,
          saved_at: configuration.saved_at
        }
      )
    )
  end

  defp membership(scope) do
    Repo.one(
      from(membership in ChannelMembership,
        where:
          membership.workspace_ref == ^scope.workspace_ref and
            membership.channel_ref == ^scope.channel_ref,
        limit: 1,
        select: %{
          deleted_at: membership.deleted_at,
          external_shared: membership.external_shared,
          generation: membership.generation,
          joined_at: membership.joined_at,
          left_at: membership.left_at,
          private: membership.private,
          status: membership.status,
          updated_at: membership.updated_at
        }
      )
    )
  end

  defp incident_room(scope) do
    Repo.one(
      from(room in IncidentRoom,
        left_join: episode in Episode,
        on: episode.id == room.episode_id,
        where:
          room.workspace_ref == ^scope.workspace_ref and room.channel_ref == ^scope.channel_ref,
        order_by: [desc: room.updated_at, desc: room.id],
        limit: 1,
        select: %{
          channel_state: room.channel_state,
          episode_ref: episode.key,
          private: room.private,
          ref: room.ref,
          repository_ref: room.repository_ref,
          status: room.status,
          title: room.title,
          updated_at: room.updated_at
        }
      )
    )
  end

  # The configured repository wins; an incident room's repository is the
  # fallback only when the channel has no configuration of its own.
  defp repository(%{repository_ref: ref}, _incident_room) when is_binary(ref),
    do: %{ref: ref, source: :configuration}

  defp repository(_configuration, %{repository_ref: ref}) when is_binary(ref),
    do: %{ref: ref, source: :incident_room}

  defp repository(_configuration, _incident_room), do: nil

  defp kind(_scope, %{}), do: :incident_room

  defp kind(scope, nil),
    do: if(ChannelScope.direct_message?(scope), do: :direct_message, else: :channel)

  # One effective participation with the layer that decided it. There is no
  # second override store to reconcile: a channel either chose, or inherits.
  defp participation(scope, configuration) do
    case ChannelSettings.effective(
           scope.workspace_ref,
           scope.conversation_ref,
           installation_participation()
         ) do
      %{} = effective ->
        Enum.map([:proactive, :shadow], fn setting ->
          %{
            revision: configuration && configuration.revision,
            scope: effective[setting].source,
            setting: setting,
            updated_at: configuration && configuration.saved_at,
            value: effective[setting].value
          }
        end)

      {:error, _reason} ->
        nil
    end
  end

  defp installation_participation do
    case Responder.Settings.fetch() do
      {:ok, settings} -> settings.slack.default_participation
      {:error, :settings_not_initialized} -> :mentions
    end
  end

  defp episodes(scope, params) do
    from(episode in Episode,
      where:
        episode.destination_transport == "slack" and
          episode.destination_conversation_ref == ^scope.conversation_ref,
      select: %{
        execution_mode: episode.execution_mode,
        ref: episode.key,
        state: episode.state,
        thread_ref: episode.destination_thread_ref,
        updated_at: episode.updated_at
      }
    )
    |> read("episode_page", [desc: :updated_at, desc: :id], params)
  end

  defp schedules(scope, params) do
    from(schedule in Schedule,
      where:
        schedule.destination_transport == "slack" and
          schedule.destination_conversation_ref == ^scope.conversation_ref,
      select: %{
        next_occurrence_at: schedule.next_occurrence_at,
        ref: schedule.ref,
        status: schedule.status,
        title: schedule.title
      }
    )
    |> read("schedule_page", [asc_nulls_last: :next_occurrence_at, desc: :id], params)
  end

  defp summaries(scope, params) do
    from(summary in ConversationSummary,
      where:
        summary.transport == "slack" and
          summary.workspace_ref == ^scope.canonical_workspace_ref and
          summary.conversation_ref == ^scope.conversation_ref,
      select: %{
        ref: summary.ref,
        repository_ref: summary.repository_ref,
        thread_ref: summary.thread_ref,
        updated_at: summary.updated_at
      }
    )
    |> read("summary_page", [desc: :updated_at, desc: :id], params)
  end

  defp read(query, key, order, params),
    do: PagedRelation.read(query, order, key, PagedRelation.requested(params, key))
end
