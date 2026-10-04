defmodule Ryker.Slack.WorkspaceAdmins do
  @moduledoc """
  Whether Slack says someone is an admin or owner of the workspace Ryker works
  in, for `Ryker.Slack.Operators`.

  Slack is asked with users.info and its answer is kept for a minute, so
  opening Home and pressing a button there asks once. Every failure is a no:
  a lookup that errors, times out or cannot be made, or this process not
  running, never lets anyone in. A failure is not kept, so the next check
  asks again.
  """

  use GenServer

  @table __MODULE__
  @ttl_ms 60_000
  @timeout_ms 5_000
  @maximum_people 5_000

  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @spec admin?(String.t(), String.t()) :: boolean()
  def admin?(workspace, user_ref) when is_binary(workspace) and is_binary(user_ref) do
    case cached({workspace, user_ref}) do
      {:ok, admin} -> admin
      :miss -> GenServer.call(__MODULE__, {:admin?, workspace, user_ref}, @timeout_ms) == true
    end
  catch
    :exit, _not_running_or_too_slow -> false
  end

  def admin?(_workspace, _user_ref), do: false

  @impl true
  def init(options) do
    workspace = Keyword.fetch!(options, :workspace)
    lookup = Keyword.fetch!(options, :lookup)

    unless is_binary(workspace) and is_function(lookup, 1),
      do: raise(ArgumentError, "workspace admins need a workspace and a lookup")

    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{workspace: workspace, lookup: lookup}}
  end

  @impl true
  def handle_call({:admin?, workspace, user_ref}, _from, %{workspace: workspace} = state) do
    # A caller that waited behind the same question finds it answered.
    case cached({workspace, user_ref}) do
      {:ok, admin} -> {:reply, admin, state}
      :miss -> {:reply, ask(state, user_ref), state}
    end
  end

  def handle_call({:admin?, _another_workspace, _user_ref}, _from, state),
    do: {:reply, false, state}

  defp ask(state, user_ref) do
    case lookup(state.lookup, user_ref) do
      {:ok, admin} when is_boolean(admin) ->
        if :ets.info(@table, :size) >= @maximum_people,
          do: :ets.delete(@table, :ets.first(@table))

        :ets.insert(@table, {{state.workspace, user_ref}, admin, now() + @ttl_ms})
        admin

      _failure ->
        false
    end
  end

  defp lookup(lookup, user_ref) do
    lookup.(user_ref)
  rescue
    error ->
      Ryker.Rescued.log("Slack admin lookup", error, __STACKTRACE__)
      {:error, :lookup_failed}
  catch
    :exit, _reason -> {:error, :lookup_failed}
  end

  defp cached(key) do
    case :ets.lookup(@table, key) do
      [{^key, admin, expires}] -> if expires > now(), do: {:ok, admin}, else: :miss
      [] -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp now, do: System.monotonic_time(:millisecond)
end
