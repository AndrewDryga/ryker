defmodule Ryker.GitHub.DeliveryPoller do
  @moduledoc """
  GitHub events for an installation GitHub cannot reach.

  GitHub sends an App's events to its webhook URL, and a Ryker on a laptop or
  behind a firewall listens on 127.0.0.1, which GitHub cannot reach. On
  2026-09-28 three comments on Ryker's own pull request ("Ryker can you bring
  this up to date?", "@ryker-bot hi" and a review comment) never arrived, and
  no GitHub event had ever been recorded on that installation.

  GitHub keeps every delivery it attempted, whether it reached the listener
  or not (`GET /app/hook/deliveries`). Every half minute this process asks for
  the newest ones and hands each it has not seen to `Ryker.GitHub.Router`
  exactly as GitHub would have: the same event, delivery id and payload,
  signed with the App's webhook secret. The router's checks, deduplication and
  routing apply unchanged, so a delivery that did reach the listener, or was
  fetched before, is taken once. One Ryker could not take is fetched again
  until it is taken (`Ryker.GitHub.Events.settled/1`).

  A delivery older than a day is not replayed: a Ryker that was off for days
  should not answer week-old comments or act on week-old CI results.
  """

  use GenServer

  require Logger

  alias Plug.Adapters.Test.Conn, as: RequestConn
  alias Ryker.Delivery.JSONClient
  alias Ryker.GitHub.{Auth, Events, Router}
  alias Ryker.Secret

  @interval_ms 30_000
  @first_poll_ms 5_000
  @page_size 100
  @oldest_seconds 24 * 60 * 60
  @remembered 5_000

  @doc false
  def child_spec(options),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}}

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl GenServer
  def init(options) do
    Process.send_after(self(), :poll, Map.get(options, :first_poll_ms, @first_poll_ms))
    {:ok, state(options)}
  end

  @doc false
  @spec state(map()) :: map()
  def state(options) do
    router = Map.fetch!(options, :router)

    %{
      app_http: Map.fetch!(options, :app_http),
      requester: Map.get(options, :requester, JSONClient),
      router: Router.init(router),
      secret: Keyword.fetch!(router, :secret),
      interval_ms: Map.get(options, :interval_ms, @interval_ms),
      clock: Map.get(options, :clock, &DateTime.utc_now/0),
      seen: MapSet.new(),
      failing: nil
    }
  end

  @impl GenServer
  def handle_info(:poll, state) do
    state = poll(state)
    Process.send_after(self(), :poll, state.interval_ms)
    {:noreply, state}
  end

  def handle_info(_unexpected, state), do: {:noreply, state}

  @doc """
  One look at GitHub's deliveries: each new one, oldest first, goes to the
  router. Returns the state with what it has now seen.
  """
  @spec poll(map()) :: map()
  def poll(state) do
    case request(state, "/app/hook/deliveries?per_page=#{@page_size}") do
      {:ok, deliveries} when is_list(deliveries) ->
        state |> recovered() |> deliver_new(deliveries)

      {:ok, _unexpected} ->
        failing(state, :unexpected_response)

      {:error, reason} ->
        failing(state, reason)
    end
  end

  defp deliver_new(state, deliveries) do
    oldest = DateTime.add(state.clock.(), -@oldest_seconds, :second)

    {fresh, stale} =
      deliveries
      |> Enum.filter(&(is_binary(&1["guid"]) and is_integer(&1["id"])))
      |> Enum.reject(&(MapSet.member?(state.seen, &1["guid"]) or &1["event"] == "ping"))
      |> Enum.uniq_by(& &1["guid"])
      |> Enum.split_with(&recent?(&1, oldest))

    settled = Events.settled(Enum.map(fresh, & &1["guid"]))
    state = remember(state, Enum.map(stale, & &1["guid"]) ++ MapSet.to_list(settled))

    fresh
    |> Enum.reject(&MapSet.member?(settled, &1["guid"]))
    |> Enum.sort_by(& &1["delivered_at"])
    |> Enum.reduce(state, &deliver/2)
  end

  defp recent?(%{"delivered_at" => at}, oldest) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, delivered_at, _offset} -> DateTime.compare(delivered_at, oldest) != :lt
      _invalid -> false
    end
  end

  defp recent?(_delivery, _oldest), do: false

  defp deliver(%{"id" => id, "guid" => guid, "event" => event_name}, state) do
    case request(state, "/app/hook/deliveries/#{id}") do
      {:ok, %{"request" => %{"payload" => %{} = payload}}} when is_binary(event_name) ->
        conn = route(state, guid, event_name, payload)

        # The router could not take it now; it is asked again next time.
        if conn.status == 503, do: state, else: remember(state, [guid])

      {:ok, _without_payload} ->
        remember(state, [guid])

      {:error, reason} ->
        failing(state, reason)
    end
  end

  defp route(state, guid, event_name, payload) do
    body = Jason.encode!(payload)

    conn =
      %Plug.Conn{}
      |> RequestConn.conn(:post, "/v1/github", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-github-event", event_name)
      |> Plug.Conn.put_req_header("x-github-delivery", guid)
      |> Plug.Conn.put_req_header(
        "x-hub-signature-256",
        Auth.signature(Secret.reveal(state.secret), body)
      )
      |> Router.call(state.router)

    # The in-process request reports its response to its caller as a message
    # too; this process reads the status from the conn, so it drops the copy.
    # Unread, it crashed the poller on its first delivery (2026-09-28).
    {_adapter, %{ref: ref}} = conn.adapter

    receive do
      {^ref, {_status, _headers, _body}} -> :ok
    after
      0 -> :ok
    end

    conn
  end

  defp request(state, path) do
    case state.requester.request(state.app_http, :get, path, nil, [
           {"accept", "application/vnd.github+json"}
         ]) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:github_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remember(state, guids) do
    seen = Enum.reduce(guids, state.seen, &MapSet.put(&2, &1))
    seen = if MapSet.size(seen) > @remembered, do: MapSet.new(guids), else: seen
    %{state | seen: seen}
  end

  # One warning when fetching starts failing, and one when it works again.
  defp failing(%{failing: nil} = state, reason) do
    Logger.warning("GitHub deliveries could not be fetched: #{inspect(reason)}")
    %{state | failing: reason}
  end

  defp failing(state, reason), do: %{state | failing: reason}

  defp recovered(%{failing: nil} = state), do: state

  defp recovered(state) do
    Logger.info("GitHub deliveries are being fetched again")
    %{state | failing: nil}
  end
end
