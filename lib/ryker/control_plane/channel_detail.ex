defmodule Ryker.ControlPlane.ChannelDetail do
  @moduledoc """
  Bounded, read-only overview of one Slack channel.

  Every field is selected explicitly and every related collection is read
  through `PagedRelation` with an exact total. Loading it never calls Slack, a
  model, Git, Coop or Emisar, never accounts a recall, and never rewrites a
  stored status: expiry and visibility are applied at read time instead.
  """
  alias Ryker.Accounting.Execution
  alias Ryker.ControlPlane.{Activity, ChannelContext, ChannelDetail, ChannelScope}
  alias Ryker.ControlPlane.{Environments, PagedRelation, Paths, RepositoryNames, UsageProjection}
  alias Ryker.Repo
  alias Ryker.Settings
  alias Ryker.Settings.Environment
  alias Ryker.Slack.ChannelSettings

  @type collection :: PagedRelation.t()

  # Every repeating relation owns one namespaced page parameter, so paging one
  # section can never reset another. Anything else in the query string is
  # dropped before it reaches a query.
  @page_keys ~w(episode_page schedule_page summary_page knowledge_page rule_page preference_page guidance_page memory_page)
  # The usage window and mode use the request directory's own names, so the
  # filtered link the page offers carries exactly the scope the page showed.
  @usage_keys ~w(usage_window mode)
  @default_window "7d"
  @default_mode "live"

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
         # The name people know each repository by, for the rules, summaries
         # and saved instructions that name one by its ref.
         repository_names: RepositoryNames.all(),
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
    mode = if params["mode"] in ~w(all shadow), do: params["mode"], else: @default_mode

    totals =
      UsageProjection.since(window)
      |> Execution.Query.ledger(mode)
      |> Execution.Query.by_conversation("slack", scope.conversation_ref)
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
          Paths.encode_query(%{
            "usage_channel" => scope.conversation_ref,
            "usage_window" => window,
            "mode" => mode
          }),
      usage_path: Paths.query("/usage", %{"window" => window, "mode" => mode})
    }
  end

  defp configuration(scope), do: Repo.one(ChannelDetail.Query.configuration(scope))

  defp membership(scope), do: Repo.one(ChannelDetail.Query.membership(scope))

  defp incident_room(scope), do: Repo.one(ChannelDetail.Query.incident_room(scope))

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
        access = Map.new(environment.repositories, &{&1.repository_ref, &1.access})

        %{
          emisar: Environments.emisar_name(settings, environment),
          name: environment.display_name,
          ref: ref,
          repositories:
            refs
            |> Enum.with_index()
            |> Enum.map(fn {repository_ref, index} ->
              repository_ref
              |> repository(settings)
              |> Map.merge(%{access: Map.get(access, repository_ref), default: index == 0})
            end),
          source: source,
          writable: List.first(refs)
        }
    end
  end

  defp none(source),
    do: %{emisar: nil, name: nil, ref: nil, repositories: [], source: source, writable: nil}

  # Whether the repository is still set up is known only once settings are.
  defp repository(ref, nil), do: %{ref: ref, name: ref, set_up: nil}

  defp repository(ref, settings),
    do: %{
      ref: ref,
      name: Environments.repository_name(settings, ref),
      set_up: Enum.any?(settings.repositories, &(&1.ref == ref))
    }

  defp default_ref(settings) do
    case Settings.default_environment(settings) do
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
      scope
      |> ChannelDetail.Query.episodes()
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
    scope
    |> ChannelDetail.Query.schedules()
    |> read("schedule_page", [asc_nulls_last: :next_occurrence_at, desc: :id], params)
  end

  defp read(query, key, order, params),
    do: PagedRelation.read(query, order, key, params)
end
