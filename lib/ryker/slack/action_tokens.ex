defmodule Ryker.Slack.ActionTokens do
  @moduledoc """
  Process-local custody for Slack Real-time Search action tokens.

  Slack supplies this credential only on a user-initiated event. It is never
  written to the inbox, episode ledger, logs, or a model prompt. The first Work
  turn that checks it out owns the token and receives at most three searches.
  """

  use GenServer

  @default_ttl_ms 15 * 60 * 1_000
  @maximum_calls 3

  @spec start_link(keyword() | map()) :: GenServer.on_start()
  def start_link(options \\ []) do
    options = options!(options)

    case options.name do
      nil -> GenServer.start_link(__MODULE__, options)
      name -> GenServer.start_link(__MODULE__, options, name: name)
    end
  end

  @spec remember(GenServer.server(), String.t(), String.t()) :: :ok | {:error, atom()}
  def remember(server \\ __MODULE__, event_ref, token) do
    with :ok <- reference(event_ref),
         :ok <- token(token) do
      GenServer.call(server, {:remember, event_ref, token})
    end
  end

  @spec checkout(GenServer.server(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, atom()}
  def checkout(server \\ __MODULE__, event_ref, turn_ref) do
    with :ok <- reference(event_ref),
         :ok <- reference(turn_ref) do
      GenServer.call(server, {:checkout, event_ref, turn_ref})
    else
      {:error, _reason} -> {:error, :slack_action_token_unavailable}
    end
  end

  @doc false
  @spec options!(keyword() | map()) :: map()
  def options!(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options),
      do: options |> Map.new() |> options!(),
      else: raise(ArgumentError, "Slack action-token options are invalid")
  end

  def options!(%{} = options) do
    allowed = [:clock, :name, :ttl_ms]

    unless Map.keys(options) -- allowed == [],
      do: raise(ArgumentError, "Slack action-token options are invalid")

    clock = Map.get(options, :clock, fn -> System.monotonic_time(:millisecond) end)
    name = Map.get(options, :name, __MODULE__)
    ttl_ms = Map.get(options, :ttl_ms, @default_ttl_ms)

    unless is_function(clock, 0),
      do: raise(ArgumentError, "Slack action-token clock is invalid")

    unless is_nil(name) or is_atom(name) or is_pid(name) or is_tuple(name),
      do: raise(ArgumentError, "Slack action-token name is invalid")

    unless is_integer(ttl_ms) and ttl_ms in 1_000..3_600_000,
      do: raise(ArgumentError, "Slack action-token lifetime is invalid")

    %{clock: clock, name: name, ttl_ms: ttl_ms}
  end

  def options!(_options), do: raise(ArgumentError, "Slack action-token options are invalid")

  @impl GenServer
  def init(options), do: {:ok, Map.put(options, :entries, %{})}

  @impl GenServer
  def handle_call({:remember, event_ref, token}, _from, state) do
    now = state.clock.()

    case Map.get(state.entries, event_ref) do
      %{token: ^token} ->
        {:reply, :ok, state}

      %{} ->
        {:reply, {:error, :slack_action_token_conflict}, state}

      nil ->
        entry = %{calls: 0, expires_at: now + state.ttl_ms, token: token, turn_ref: nil}
        {:reply, :ok, put_in(state, [:entries, event_ref], entry)}
    end
  end

  def handle_call({:checkout, event_ref, turn_ref}, _from, state) do
    now = state.clock.()

    case Map.get(state.entries, event_ref) do
      %{expires_at: expires_at} when expires_at <= now ->
        {:reply, {:error, :slack_action_token_unavailable},
         update_in(state.entries, &Map.delete(&1, event_ref))}

      %{turn_ref: owner} when not is_nil(owner) and owner != turn_ref ->
        {:reply, {:error, :slack_action_token_not_authorized}, state}

      %{calls: calls} when calls >= @maximum_calls ->
        {:reply, {:error, :slack_search_budget_exhausted}, state}

      %{} = entry ->
        claimed = %{entry | calls: entry.calls + 1, turn_ref: turn_ref}
        {:reply, {:ok, entry.token}, put_in(state, [:entries, event_ref], claimed)}

      nil ->
        {:reply, {:error, :slack_action_token_unavailable}, state}
    end
  end

  defp reference(value) do
    if is_binary(value) and byte_size(value) in 1..1_024 and String.valid?(value) and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: :ok,
       else: {:error, :invalid_slack_action_token}
  end

  defp token(value) do
    if is_binary(value) and byte_size(value) in 1..4_096 and String.valid?(value) and
         :binary.match(value, <<0>>) == :nomatch,
       do: :ok,
       else: {:error, :invalid_slack_action_token}
  end
end
