defmodule Ryker.CoopFleet.ModelSocket do
  @moduledoc false
  @behaviour WebSock
  alias Ryker.CoopFleet.{ModelPermits, ModelRequest, ModelSocketLedger, ModelSocketUpstream}

  defmodule State do
    @moduledoc false
    @derive {Inspect, except: [:authorize, :binding]}
    defstruct [
      :upstream,
      :monitor,
      :authorize,
      :job,
      :provider,
      :account,
      :binding,
      ledger: %ModelSocketLedger{}
    ]
  end

  @impl true
  def init(options) do
    case ModelSocketUpstream.attach(options.upstream) do
      :ok ->
        Process.send_after(self(), :check_model_authority, 1_000)
        {:ok, struct!(State, Map.put(options, :monitor, Process.monitor(options.upstream)))}

      _closed ->
        {:stop, :normal, {1011, "provider unavailable"}, %State{}}
    end
  catch
    :exit, _closed -> {:stop, :normal, {1011, "provider unavailable"}, %State{}}
  end

  @impl true
  def handle_in({data, metadata}, state) do
    with :text <- metadata[:opcode],
         {:ok, event} <- ModelRequest.websocket(state.job, state.provider, state.account, data),
         {:ok, _current} <- state.authorize.() do
      forward_request(state, event, data)
    else
      _refused -> {:stop, :normal, {1008, "model request refused"}, state}
    end
  catch
    :exit, _closed -> {:stop, :normal, {1011, "provider unavailable"}, state}
  end

  defp forward_request(state, %{kind: :create, lane: lane}, data) do
    case ModelPermits.reserve(state.binding, state.authorize, :websocket) do
      {:ok, lease} ->
        with {:ok, _remaining} <- ModelPermits.activate(lease, state.upstream),
             :ok <- ModelSocketUpstream.send_frame(state.upstream, {:text, data}) do
          {:ok, %{state | ledger: ModelSocketLedger.enqueue(state.ledger, lane, lease)}}
        else
          _closed -> {:stop, :normal, {1011, "provider unavailable"}, state}
        end

      {:error, {:model_limited, reason, until}} ->
        retry = if until, do: max(1, DateTime.diff(until, Ryker.Repo.now!(), :second)), else: 1

        event = %{
          type: "error",
          status: if(reason == :unresolved_requests, do: 503, else: 429),
          error: %{
            type: "rate_limit_error",
            code: "coop_model_#{reason}",
            message: "This model account cannot accept another inference request yet.",
            headers: %{"retry-after" => Integer.to_string(retry)}
          }
        }

        event = if lane, do: Map.put(event, :stream_id, lane), else: event
        {:push, {:text, Jason.encode!(event)}, state}

      _refused ->
        {:stop, :normal, {1011, "model capacity unavailable"}, state}
    end
  end

  defp forward_request(state, %{kind: :interrupt}, data) do
    case ModelSocketUpstream.send_frame(state.upstream, {:text, data}) do
      :ok -> {:ok, state}
      _closed -> {:stop, :normal, {1011, "provider unavailable"}, state}
    end
  end

  @impl true
  def handle_info(:check_model_authority, state) do
    case state.authorize.() do
      {:ok, _current} ->
        Process.send_after(self(), :check_model_authority, 1_000)
        {:ok, state}

      _revoked ->
        {:stop, :normal, {1008, "model authority ended"}, state}
    end
  end

  def handle_info(
        {:model_socket_frame, upstream, {:text, data} = frame},
        %{upstream: upstream} = state
      ) do
    observe_limit(state.binding, data)

    case ModelSocketLedger.receive_event(state.ledger, data) do
      {:ok, ledger, nil} ->
        {:push, frame, %{state | ledger: ledger}}

      {action, ledger, {lease, id}} when action in [:bind, :complete] ->
        finish_event(action, ledger, lease, id, frame, state)

      {:error, _event} ->
        {:stop, :normal, {1011, "provider request failed"}, frame, state}

      :invalid ->
        {:stop, :normal, {1011, "provider response invalid"}, state}
    end
  catch
    :exit, _closed -> {:stop, :normal, {1011, "model request ended"}, state}
  end

  def handle_info({:model_socket_frame, upstream, _invalid}, %{upstream: upstream} = state),
    do: {:stop, :normal, {1003, "provider response invalid"}, state}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = state),
    do: {:stop, :normal, state}

  def handle_info(_message, state), do: {:ok, state}

  defp finish_event(action, ledger, lease, id, frame, state) do
    result =
      if action == :bind,
        do: ModelPermits.bind_response(lease, id),
        else: ModelPermits.complete(lease, id)

    case result do
      :ok -> {:push, frame, %{state | ledger: ledger}}
      _changed -> {:stop, :normal, {1011, "model request ended"}, state}
    end
  end

  defp observe_limit(binding, data) do
    with {:ok, event} <- Jason.decode(data),
         true <- is_map(event),
         error when is_map(error) <- provider_error(event),
         true <- rate_limited?(event, error) do
      headers = retry_headers(error["headers"]) ++ retry_headers(event["headers"])
      ModelPermits.observe_limit(binding, headers)
    else
      _ordinary -> :ok
    end
  end

  defp provider_error(%{"type" => "error"} = event), do: event["error"]

  defp provider_error(%{"type" => "response.failed", "response" => response})
       when is_map(response), do: response["error"]

  defp provider_error(_event), do: nil

  defp rate_limited?(event, error) do
    event["status"] == 429 or event["status_code"] == 429 or
      error["code"] == "rate_limit_exceeded" or error["type"] == "usage_limit_reached"
  end

  defp retry_headers(headers) when is_map(headers) do
    Enum.filter(headers, fn {name, value} ->
      is_binary(name) and String.downcase(name) == "retry-after" and is_binary(value)
    end)
  end

  defp retry_headers(_headers), do: []

  @impl true
  def terminate(_reason, %State{upstream: nil}), do: :ok

  def terminate(_reason, state) do
    if Process.alive?(state.upstream), do: GenServer.stop(state.upstream, :normal)
    :ok
  catch
    :exit, _closed -> :ok
  end
end
