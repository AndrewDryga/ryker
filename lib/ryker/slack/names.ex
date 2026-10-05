defmodule Ryker.Slack.Names do
  @moduledoc """
  Workspace-scoped display cache: the names of Slack people, channels and the
  workspace, for reading. Never an authorization source or a dependency of
  rendering.

  A page asks while it is drawn and gets what is known now, or a kind word
  when nothing is ("Slack user", "Slack channel C123"). Slack is then asked in
  the background, one name a tick, and a page that shows Slack names is told
  when one arrives or changes (`subscribe_names/0`), so it draws again without
  a reload. Names Ryker already has in hand, such as the members Choose people
  lists, are kept at once (`remember/1`).

  The owner runs it whenever Slack's tokens are verified, switched on or not,
  apart from every other Slack setting, so choosing who can manage Ryker (and
  switching Slack on by doing so) keeps the names it knows.
  """
  use GenServer
  alias Ryker.InspectionRedactor
  alias Ryker.Slack.Client

  @table __MODULE__
  @ttl 900_000
  @interval 1600
  @maximum_names 2000
  @workspace_url ~r/\Ahttps:\/\/[a-z0-9-]{1,64}\.slack\.com\z/

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @doc """
  Checks what assembly hands the owner for this cache: the workspace, its
  saved address (nil when unknown) and the bot's client. The owner turns the
  client into the lookup.
  """
  @spec options!(map()) :: map()
  def options!(%{workspace: workspace, workspace_url: url, client: %Client{}} = configuration)
      when is_binary(workspace) and (is_nil(url) or is_binary(url)),
      do: configuration

  def options!(_configuration),
    do: raise(ArgumentError, "Slack names need a workspace, its address and a client")

  def name(workspace, ref) when is_binary(workspace) and is_binary(ref) do
    key = {workspace, ref}

    case cached(key) do
      [{^key, label, expires}] ->
        if expires <= now(), do: request(workspace, ref)
        display(ref, label)

      [] ->
        request(workspace, ref)
        unresolved(ref)
    end
  end

  def name(_, _), do: "Slack reference"

  @doc """
  A Slack person the one way every page shows them: `name` is "@Name" once
  Slack has said it and "Slack user" until then, never the raw ID, and `href`
  opens their profile, in the workspace when its address is known and through
  Slack when not. Anything that is not a person's reference Slack would
  accept has no link. The ref may carry the `slack:user:` prefix actor refs
  use.
  """
  @spec person(String.t() | nil, String.t() | nil) :: %{
          name: String.t(),
          href: String.t() | nil
        }
  def person(workspace, "slack:user:" <> ref), do: person(workspace, ref)

  def person(workspace, <<prefix, _::binary>> = ref)
      when is_binary(workspace) and prefix in [?U, ?W] do
    if valid_ref?(ref) and valid_ref?(workspace),
      do: %{name: name(workspace, ref), href: profile_url(workspace, ref)},
      else: nobody()
  end

  def person(_workspace, _ref), do: nobody()

  @doc "Whether a reference names a Slack person, bare (`U…`) or as an actor (`slack:user:U…`)."
  @spec person_ref?(term()) :: boolean()
  def person_ref?("slack:user:" <> ref), do: person_ref?(ref)
  def person_ref?(<<prefix, _::binary>> = ref) when prefix in [?U, ?W], do: valid_ref?(ref)
  def person_ref?(_ref), do: false

  @doc """
  Keeps names Ryker already has in hand, such as the members Choose people
  just listed, so pages show them at once instead of asking Slack for each.
  Each entry is `{workspace, ref, name}`; only this cache's workspace is kept.
  Without a running cache there is nowhere to keep them, and that is fine.
  """
  @spec remember([{String.t(), String.t(), String.t()}]) :: :ok
  def remember(entries) when is_list(entries) do
    if is_pid(Process.whereis(__MODULE__)),
      do: GenServer.call(__MODULE__, {:remember, entries}),
      else: :ok
  catch
    :exit, _not_running -> :ok
  end

  def destination("slack:" <> rest) do
    case String.split(rest, ":", parts: 3) do
      [workspace, ref] -> name(workspace, ref)
      [workspace, ref, _thread] -> name(workspace, ref) <> " · thread"
      _ -> "Slack conversation"
    end
  end

  def destination("control_plane:" <> _), do: "Direct conversation"
  def destination("control-plane:lab:" <> _), do: "Direct conversation"
  def destination(value), do: value

  @doc """
  Whether a destination resolved to a real Slack name.

  Callers used to ask this by comparing the rendered string to "Slack channel",
  which made a display fallback an API: the moment that text carried the
  reference as well, the comparison silently stopped matching.
  """
  def named?("slack:" <> rest) do
    case String.split(rest, ":", parts: 3) do
      [workspace, ref | _] -> resolved?(workspace, ref)
      _ -> false
    end
  end

  def named?(_destination), do: false

  def workspace_from_destination("slack:" <> rest),
    do: rest |> String.split(":", parts: 2) |> hd()

  def workspace_from_destination(_), do: nil

  @doc """
  A number that grows each time a name any page could show arrives or
  changes. Data drawn with names while the page is drawn, rather than with
  names read into the data, carries it, so the next refresh sees a change and
  draws those names again.
  """
  @spec revision() :: non_neg_integer()
  def revision do
    case cached(:revision) do
      [{:revision, revision}] -> revision
      [] -> 0
    end
  end

  @doc """
  The Slack channels whose known name contains `text`, ignoring case and a
  leading `#`, as the `slack:<workspace>:<channel>` references requests carry,
  so a search finds a request by the channel name its row shows.
  """
  @spec conversations_named(String.t()) :: [String.t()]
  def conversations_named(text) when is_binary(text) do
    case text |> String.trim() |> String.trim_leading("#") |> String.downcase() do
      "" ->
        []

      needle ->
        for {{workspace, <<prefix, _::binary>> = ref}, label, _expires} <- names(),
            prefix in [?C, ?G] and is_binary(label),
            String.contains?(String.downcase(label), needle),
            do: "slack:#{workspace}:#{ref}"
    end
  end

  defp names do
    :ets.select(@table, [{{{:_, :_}, :_, :_}, [], [:"$_"]}])
  rescue
    ArgumentError -> []
  end

  @doc "The workspace whose names the running cache serves, or nil when none runs."
  @spec workspace() :: String.t() | nil
  def workspace do
    case cached(:origin) do
      [{:origin, workspace, _url}] -> workspace
      [] -> nil
    end
  end

  @impl true
  def init(options) do
    case settings(options) do
      {:ok, workspace, workspace_url, fetch} ->
        :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
        :ets.insert(@table, {:origin, workspace, workspace_url})
        keep_known(workspace, Keyword.get(options, :known, []))
        Process.send_after(self(), :tick, @interval)

        {:ok,
         %{
           workspace: workspace,
           fetch: fetch,
           queue: :queue.new(),
           pending: MapSet.new(),
           blocked_until: now()
         }}

      :disabled ->
        :ignore
    end
  end

  @impl true
  def handle_cast({:resolve, workspace, ref}, %{workspace: workspace} = state) do
    if valid_ref?(ref) and not fresh?({workspace, ref}) and MapSet.size(state.pending) < 1000 and
         not MapSet.member?(state.pending, ref) do
      {:noreply,
       %{state | queue: :queue.in(ref, state.queue), pending: MapSet.put(state.pending, ref)}}
    else
      {:noreply, state}
    end
  end

  def handle_cast({:resolve, _, _}, state), do: {:noreply, state}

  @impl true
  def handle_info(:tick, state) do
    state = refresh_one(state)
    Process.send_after(self(), :tick, @interval)
    {:noreply, state}
  end

  @impl true
  def handle_call(:refresh, _from, state), do: {:reply, :ok, refresh_one(state)}

  def handle_call({:remember, entries}, _from, %{workspace: workspace} = state) do
    changed =
      Enum.reduce(entries, false, fn
        {^workspace, ref, label}, changed when is_binary(ref) ->
          if valid_ref?(ref) and valid_label?(label),
            do: store(workspace, ref, clean(label), @ttl) or changed,
            else: changed

        _another_workspace, changed ->
          changed
      end)

    if changed, do: announce()
    {:reply, :ok, state}
  end

  defp refresh_one(state) do
    if state.blocked_until > now(), do: state, else: fetch_next(state)
  end

  defp fetch_next(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, ref}, queue} ->
        state = %{state | queue: queue, pending: MapSet.delete(state.pending, ref)}

        # Remembered since it was asked for: nothing to ask Slack.
        if remembered?({state.workspace, ref}), do: state, else: look_up(state, ref)
    end
  end

  defp look_up(state, ref) do
    {label, ttl, backoff} =
      case fetch(state.fetch, ref) do
        {:ok, label} when is_binary(label) and byte_size(label) in 1..160 ->
          {clean(label), @ttl, 0}

        {:error, {:delivery_rate_limited, seconds, _}} when is_integer(seconds) ->
          {nil, max(seconds * 1000, 60_000), max(seconds * 1000, 60_000)}

        _ ->
          {nil, 300_000, 0}
      end

    if store(state.workspace, ref, label, ttl), do: announce()
    %{state | blocked_until: now() + backoff}
  end

  # Names Ryker knows before Slack is asked, such as its own bot user's from
  # its settings: right after a restart, "Hi @Ryker" read "Hi Slack user"
  # until the cache had looked Ryker up (2026-09-26).
  defp keep_known(workspace, known) when is_list(known) do
    for {ref, label} <- known, is_binary(ref), valid_ref?(ref), valid_label?(label) do
      store(workspace, ref, clean(label), @ttl)
    end
  end

  defp keep_known(_workspace, _known), do: []

  # This is disposable presentation data, not durable identity or authority.
  # A lookup that failed keeps the name Slack gave before, if any. Whether
  # what a page would show changed is the answer.
  defp store(workspace, ref, label, ttl) do
    key = {workspace, ref}

    previous =
      case :ets.lookup(@table, key) do
        [{^key, known, _expires}] -> known
        [] -> nil
      end

    evict()
    :ets.insert(@table, {key, label || previous, now() + ttl})
    is_binary(label) and label != previous
  end

  # The workspace's own entry is not a name and never makes room.
  defp evict do
    if :ets.info(@table, :size) >= @maximum_names do
      case :ets.select(
             @table,
             [{{{:"$1", :_}, :_, :_}, [{:is_binary, :"$1"}], [{:element, 1, :"$_"}]}],
             1
           ) do
        {[key], _continuation} -> :ets.delete(@table, key)
        _empty -> :ok
      end
    end
  end

  defp announce do
    revision = :ets.update_counter(@table, :revision, 1, {:revision, 0})
    Ryker.PubSub.broadcast(names_topic(), {:slack_names_updated, revision})
  end

  defp clean(label), do: InspectionRedactor.artifact(label, max_bytes: 160).text

  defp valid_label?(label), do: is_binary(label) and byte_size(String.trim(label)) in 1..160

  # The caller supplies the workspace and the lookup. Reading them back out of the
  # application environment here is what let this process decline with `:ignore`
  # when it happened to start before that environment was published — and an
  # `:ignore` is permanent, so the cache stayed dead and every name in the
  # control plane rendered as its kind.
  defp settings(options) do
    case {Keyword.get(options, :workspace), Keyword.get(options, :fetch)} do
      {workspace, fetch} when is_binary(workspace) and is_function(fetch, 1) ->
        {:ok, workspace, workspace_url(Keyword.get(options, :workspace_url)), fetch}

      _unconfigured ->
        :disabled
    end
  end

  # Only a Slack workspace's own origin ever becomes a link.
  defp workspace_url(url) when is_binary(url) do
    url = String.trim_trailing(url, "/")
    if Regex.match?(@workspace_url, url), do: url
  end

  defp workspace_url(_url), do: nil

  defp profile_url(workspace, ref) do
    case cached(:origin) do
      [{:origin, ^workspace, url}] when is_binary(url) ->
        url <> "/team/" <> ref

      _unknown ->
        "https://slack.com/app_redirect?" <> URI.encode_query(team: workspace, channel: ref)
    end
  end

  defp fetch(fetch, ref) do
    fetch.(ref)
  rescue
    error ->
      Ryker.Rescued.log("Slack name lookup", error, __STACKTRACE__)
      {:error, :directory_unavailable}
  catch
    :exit, _ -> {:error, :directory_unavailable}
  end

  defp resolved?(workspace, ref) when is_binary(workspace) and is_binary(ref) do
    match?([{_key, label, _expires}] when is_binary(label), cached({workspace, ref}))
  end

  defp resolved?(_workspace, _ref), do: false

  defp remembered?(key) do
    case cached(key) do
      [{^key, label, expires}] -> is_binary(label) and expires > now()
      [] -> false
    end
  end

  defp fresh?(key) do
    case cached(key) do
      [{^key, _label, expires}] -> expires > now()
      [] -> false
    end
  end

  defp cached(key) do
    :ets.lookup(@table, key)
  rescue
    ArgumentError -> []
  end

  defp request(workspace, ref) do
    if is_pid(Process.whereis(__MODULE__)) and valid_ref?(ref),
      do: GenServer.cast(__MODULE__, {:resolve, workspace, ref})
  end

  defp nobody, do: %{name: "Slack user", href: nil}

  defp valid_ref?(ref), do: byte_size(ref) <= 64 and Regex.match?(~r/\A[TCGDUWA][A-Z0-9]+\z/, ref)
  defp display(ref, nil), do: unresolved(ref)
  defp display(<<prefix, _::binary>>, label) when prefix in [?C, ?G], do: "#" <> label
  defp display(<<prefix, _::binary>>, label) when prefix in [?U, ?W], do: "@" <> label
  defp display(_, label), do: label

  # The channels page listed five identical "Slack channel" rows with the
  # reference only in a tooltip, so nothing on screen told #test from #test2:
  # a channel keeps its reference. A person never shows as a raw ID (Andrew,
  # 2026-09-26); their profile link tells two people apart. A reference Slack
  # itself would reject is never echoed back into the page.
  defp unresolved(<<prefix, _::binary>>) when prefix in [?U, ?W], do: "Slack user"

  defp unresolved(ref) do
    if valid_ref?(ref), do: fallback(ref) <> " " <> ref, else: fallback(ref)
  end

  defp fallback(<<prefix, _::binary>>) when prefix in [?C, ?G], do: "Slack channel"
  defp fallback("D" <> _), do: "Direct message"
  defp fallback("T" <> _), do: "Slack workspace"
  defp fallback("A" <> _), do: "Slack app"
  defp fallback(_), do: "Slack reference"
  defp now, do: System.monotonic_time(:millisecond)

  # -- PubSub ------------------------------------------------------------------

  @doc """
  Subscribes the caller to the names cache: `{:slack_names_updated, revision}`
  once a name a page may show arrives from Slack or changes. `revision`
  counts the changes since the cache started; the names are read through
  `name/2`, `person/2` and `destination/1`.
  """
  def subscribe_names, do: Ryker.PubSub.subscribe(names_topic())

  def unsubscribe_names, do: Ryker.PubSub.unsubscribe(names_topic())

  defp names_topic, do: "slack:names"
end
