defmodule Ryker.ControlPlane.SlackNames do
  @moduledoc "Workspace-scoped display cache. Never an authorization source or a dependency of rendering."
  use GenServer
  alias Ryker.ControlPlane.InspectionRedactor
  @table __MODULE__
  @ttl 900_000
  @interval 1600

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

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

  def workspace do
    case Application.get_env(:ryker, :slack) do
      %{identity: %{workspace_ref: workspace}} -> workspace
      options when is_list(options) -> get_in(options, [:identity, :workspace_ref])
      _ -> nil
    end
  end

  @impl true
  def init(options) do
    case settings(options) do
      {:ok, workspace, fetch} ->
        :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
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

  defp refresh_one(state) do
    if state.blocked_until > now(), do: state, else: fetch_next(state)
  end

  defp fetch_next(state) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, ref}, queue} ->
        {label, ttl, backoff} =
          case fetch(state.fetch, ref) do
            {:ok, label} when is_binary(label) and byte_size(label) in 1..160 ->
              {InspectionRedactor.artifact(label, max_bytes: 160).text, @ttl, 0}

            {:error, {:delivery_rate_limited, seconds, _}} when is_integer(seconds) ->
              {nil, max(seconds * 1000, 60_000), max(seconds * 1000, 60_000)}

            _ ->
              {nil, 300_000, 0}
          end

        # This is disposable presentation data, not durable identity or authority.
        if :ets.info(@table, :size) >= 2000, do: :ets.delete(@table, :ets.first(@table))
        :ets.insert(@table, {{state.workspace, ref}, label, now() + ttl})

        %{
          state
          | queue: queue,
            pending: MapSet.delete(state.pending, ref),
            blocked_until: now() + backoff
        }
    end
  end

  # The caller supplies the workspace and the lookup. Reading them back out of the
  # application environment here is what let this process decline with `:ignore`
  # when it happened to start before that environment was published — and an
  # `:ignore` is permanent, so the cache stayed dead and every name in the
  # control plane rendered as its kind.
  defp settings(options) do
    case {Keyword.get(options, :workspace), Keyword.get(options, :fetch)} do
      {workspace, fetch} when is_binary(workspace) and is_function(fetch, 1) ->
        {:ok, workspace, fetch}

      _unconfigured ->
        :disabled
    end
  end

  defp fetch(fetch, ref) do
    fetch.(ref)
  rescue
    _ -> {:error, :directory_unavailable}
  catch
    :exit, _ -> {:error, :directory_unavailable}
  end

  defp resolved?(workspace, ref) when is_binary(workspace) and is_binary(ref) do
    match?([{_key, label, _expires}] when is_binary(label), cached({workspace, ref}))
  end

  defp resolved?(_workspace, _ref), do: false

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

  defp valid_ref?(ref), do: byte_size(ref) <= 64 and Regex.match?(~r/\A[TCGDUWA][A-Z0-9]+\z/, ref)
  defp display(ref, nil), do: unresolved(ref)
  defp display(<<prefix, _::binary>>, label) when prefix in [?C, ?G], do: "#" <> label
  defp display(<<prefix, _::binary>>, label) when prefix in [?U, ?W], do: "@" <> label
  defp display(_, label), do: label
  # The channels page listed five identical "Slack channel" rows with the
  # reference only in a tooltip, so nothing on screen told #test from #test2.
  # A reference Slack itself would reject is never echoed back into the page.
  defp unresolved(ref) do
    if valid_ref?(ref), do: fallback(ref) <> " " <> ref, else: fallback(ref)
  end

  defp fallback(<<prefix, _::binary>>) when prefix in [?C, ?G], do: "Slack channel"
  defp fallback("D" <> _), do: "Direct message"
  defp fallback("T" <> _), do: "Slack workspace"
  defp fallback(<<prefix, _::binary>>) when prefix in [?U, ?W], do: "Slack user"
  defp fallback("A" <> _), do: "Slack app"
  defp fallback(_), do: "Slack reference"
  defp now, do: System.monotonic_time(:millisecond)
end
