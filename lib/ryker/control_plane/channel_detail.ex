defmodule Ryker.ControlPlane.ChannelDetail do
  @moduledoc """
  Bounded, read-only overview of one Slack channel.

  Every field is selected explicitly and every related collection is read
  through `PagedRelation` with an exact total. Loading it never calls Slack, a
  model, Git, Coop or Emisar, never accounts a recall, and never rewrites a
  stored status: expiry and visibility are applied at read time instead.
  """

  import Ecto.Query

  alias Ryker.Accounting.Query, as: AccountingQuery

  alias Ryker.ControlPlane.{
    Activity,
    ChannelContext,
    ChannelScope,
    Environments,
    PagedRelation,
    UsageProjection
  }

  alias Ryker.Episodes.Episode
  alias Ryker.Repo
  alias Ryker.Settings.Environment
  alias Ryker.Slack.{ChannelConfiguration, ChannelMembership, ChannelSettings, IncidentRoom}
  alias Ryker.State.Schedule

  @type collection :: PagedRelation.t()

  # Every repeating relation owns one namespaced page parameter, so paging one
  # section can never reset another. Anything else in the query string is
  # dropped before it reaches a query.
  @page_keys ~w(episode_page schedule_page summary_page knowledge_page rule_page preference_page guidance_page memory_page)
  # The usage window and mode use the request directory's own names, so the
  # filtered link the page offers carries exactly the scope the page showed.
  @usage_keys ~w(usage_window mode)
  @default_window "7d"
  @default_mode "all"

  @doc "The query parameters the channel route accepts."
  @spec query_keys() :: [String.t()]
  def query_keys, do: @page_keys ++ @usage_keys

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
    settings = settings()
    configuration = configuration(scope)
    membership = membership(scope)
    incident_room = incident_room(scope)
    environment = environment(configuration, incident_room, settings)
    scope = ChannelScope.with_repository(scope, environment.writable)
    episodes = episodes(scope, params)

    if is_nil(configuration) and is_nil(membership) and is_nil(incident_room) and
         episodes.total == 0 do
      :not_found
    else
      relations = %{
        episodes: episodes,
        schedules: schedules(scope, params),
        summaries: ChannelContext.summaries(scope, params),
        knowledge: ChannelContext.knowledge(scope, params),
        rules: ChannelContext.rules(scope, params),
        preferences: ChannelContext.preferences(scope, params),
        guidance: ChannelContext.guidance(scope, params),
        memory: ChannelContext.memory(scope, params)
      }

      usage = usage(scope, params)

      {:ok,
       Map.merge(relations, %{
         scope: scope,
         params: Map.merge(link_params(Map.values(relations)), usage_params(usage)),
         usage: usage,
         channel: %{
           kind: kind(scope, incident_room),
           membership: membership,
           configuration: configuration,
           incident_room: incident_room,
           environment: environment
         },
         environments: choices(settings),
         participation: participation(scope, settings),
         continuity: ChannelContext.continuity(scope),
         learning: ChannelContext.learning_status(scope)
       })}
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

  defp usage_params(usage) do
    %{"usage_window" => usage.window, "mode" => usage.mode}
    |> Map.reject(fn {key, value} ->
      (key == "usage_window" and value == @default_window) or
        (key == "mode" and value == @default_mode)
    end)
  end

  # The same deduplicated ledger, window and mode defaults as /usage, narrowed
  # to this exact conversation. Coverage travels with every figure: a turn
  # that reported no tokens or carried no price is counted, not summed as zero.
  defp usage(scope, params) do
    window = UsageProjection.window(params["usage_window"])
    mode = if params["mode"] in ~w(live shadow), do: params["mode"], else: @default_mode

    totals =
      UsageProjection.since(window)
      |> AccountingQuery.executions(mode)
      |> where([e], e.transport == "slack" and e.conversation_ref == ^scope.conversation_ref)
      |> UsageProjection.totals()

    %{
      window: window,
      mode: mode,
      executions: totals.attempts,
      measured: totals.usage_measured,
      costed: totals.costed,
      input_tokens: totals.input_tokens,
      cached_input_tokens: totals.cached_input_tokens,
      output_tokens: totals.output_tokens,
      reasoning_tokens: totals.reasoning_tokens,
      cost_usd: if(totals.costed > 0, do: totals.cost_usd),
      link:
        "/activity?" <>
          URI.encode_query(%{
            "usage_channel" => scope.conversation_ref,
            "usage_window" => window,
            "mode" => mode
          }),
      usage_path: "/usage?" <> URI.encode_query(%{"window" => window, "mode" => mode})
    }
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
          environment_ref: configuration.environment_ref,
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

  defp settings do
    case Ryker.Settings.fetch() do
      {:ok, snapshot} -> snapshot
      {:error, :settings_not_initialized} -> nil
    end
  end

  # Where the channel's work runs, and so which repository its inherited
  # rules, guidance and memory resolve through. A channel with its own
  # setting works in the environment it chose, or in none; an incident room
  # without one keeps the repository it was opened with; any other
  # conversation works in the default environment.
  defp environment(%{environment_ref: ref}, _incident_room, settings),
    do: described(ref, :channel, settings)

  defp environment(nil, %{repository_ref: ref}, settings) when is_binary(ref),
    do: %{none(:incident_room) | repositories: [repository(ref, settings)], writable: ref}

  defp environment(nil, %{}, _settings), do: none(:incident_room)

  defp environment(nil, nil, settings),
    do: described(settings && default_ref(settings), :default, settings)

  defp described(nil, source, _settings), do: none(source)

  defp described(ref, source, settings) do
    case settings && Environments.find(settings, ref) do
      nil ->
        %{none(source) | ref: ref, name: ref}

      environment ->
        refs = Environment.repository_refs(environment)

        %{
          emisar: Environments.emisar_name(settings, environment),
          name: environment.display_name,
          ref: ref,
          repositories: Enum.map(refs, &repository(&1, settings)),
          source: source,
          writable: List.first(refs)
        }
    end
  end

  defp none(source),
    do: %{emisar: nil, name: nil, ref: nil, repositories: [], source: source, writable: nil}

  defp repository(ref, nil), do: %{ref: ref, name: ref}

  defp repository(ref, settings),
    do: %{ref: ref, name: Environments.repository_name(settings, ref)}

  defp default_ref(settings) do
    case Environment.default(settings) do
      %Environment{ref: ref} -> ref
      nil -> nil
    end
  end

  # What a channel can choose between on its page, the default first.
  defp choices(nil), do: []

  defp choices(settings) do
    for environment <- Environments.ordered(settings.environments),
        do: %{ref: environment.ref, name: environment.display_name}
  end

  defp kind(_scope, %{}), do: :incident_room

  defp kind(scope, nil),
    do: if(ChannelScope.direct_message?(scope), do: :direct_message, else: :channel)

  # One effective participation and the layer that decided it: the channel's
  # own choice, or the installation default it inherits. There is no second
  # override store to reconcile.
  defp participation(scope, settings) do
    case ChannelSettings.effective(
           scope.workspace_ref,
           scope.conversation_ref,
           if(settings, do: settings.slack.default_participation, else: :mentions)
         ) do
      %{} = effective -> ChannelSettings.effective_participation(effective)
      {:error, _reason} -> nil
    end
  end

  defp episodes(scope, params) do
    relation =
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

    # An episode is named by what was asked, the way the Activity page names
    # it; the key stays beside the title as the secondary fact.
    titles = Activity.request_titles(Enum.map(relation.items, & &1.ref))

    %{
      relation
      | items:
          Enum.map(relation.items, fn item ->
            Map.put(item, :title, titles[item.ref] && titles[item.ref].title)
          end)
    }
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

  defp read(query, key, order, params),
    do: PagedRelation.read(query, order, key, params)
end
