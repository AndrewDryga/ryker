defmodule Ryker.CoopFleet.ModelSocketUpstream do
  @moduledoc false
  use GenServer
  alias Ryker.Secret

  defmodule State do
    @moduledoc false
    @derive {Inspect, except: [:conn, :websocket, :initial]}
    defstruct [:conn, :request, :websocket, :owner, :monitor, :initial]
  end

  # Own the provider connection before the browser-facing upgrade. This keeps
  # provider authentication and quota failures as HTTP responses.
  def connect(options, connector \\ &provider_connection/1) do
    GenServer.start(
      __MODULE__,
      options |> Map.put(:owner, self()) |> Map.put(:connector, connector)
    )
  end

  def attach(pid), do: GenServer.call(pid, {:attach, self()})
  def send_frame(pid, frame), do: GenServer.call(pid, {:send, frame})

  @impl true
  def init(options) do
    case open(options) do
      {:ok, conn, request, websocket, initial} ->
        Process.send_after(self(), :attach_deadline, 10_000)

        {:ok,
         %State{
           conn: conn,
           request: request,
           websocket: websocket,
           initial: initial,
           owner: options.owner,
           monitor: Process.monitor(options.owner)
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:attach, owner}, _from, state) do
    Process.demonitor(state.monitor, [:flush])
    state = %{state | owner: owner, monitor: Process.monitor(owner)}
    send(self(), :deliver_initial)
    {:reply, :ok, state}
  end

  def handle_call({:send, frame}, _from, state) do
    case write(state, frame) do
      {:ok, state} -> {:reply, :ok, state}
      :closed -> {:stop, :normal, {:error, :closed}, state}
    end
  end

  @impl true
  def handle_info(:attach_deadline, %{initial: nil} = state), do: {:noreply, state}
  def handle_info(:attach_deadline, state), do: {:stop, :normal, state}

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = state),
    do: {:stop, :normal, state}

  def handle_info(:deliver_initial, state),
    do: decode(%{state | initial: nil}, state.initial || "")

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        Enum.reduce_while(responses, {:noreply, %{state | conn: conn}}, fn
          {:data, request, bytes}, {:noreply, %{request: request} = current} ->
            continue_decode(current, bytes)

          _other, {:noreply, current} ->
            {:halt, {:stop, :normal, current}}
        end)

      :unknown ->
        {:noreply, state}

      _closed ->
        {:stop, :normal, state}
    end
  end

  defp continue_decode(current, bytes) do
    case decode(current, bytes) do
      {:noreply, next} -> {:cont, {:noreply, next}}
      closed -> {:halt, closed}
    end
  end

  @impl true
  def terminate(_reason, state), do: Mint.HTTP.close(state.conn)

  defp decode(state, ""), do: {:noreply, state}

  defp decode(state, bytes) do
    case Mint.WebSocket.decode(state.websocket, bytes) do
      {:ok, websocket, frames} ->
        Enum.reduce_while(frames, {:noreply, %{state | websocket: websocket}}, fn
          {:ping, data}, {:noreply, current} ->
            reply_ping(current, data)

          {:pong, _}, result ->
            {:cont, result}

          {kind, data}, {:noreply, current} when kind in [:text, :binary] ->
            send(current.owner, {:model_socket_frame, self(), {kind, data}})
            {:cont, {:noreply, current}}

          _closed, {:noreply, current} ->
            {:halt, {:stop, :normal, current}}
        end)

      _invalid ->
        {:stop, :normal, state}
    end
  end

  defp reply_ping(current, data) do
    case write(current, {:pong, data}) do
      {:ok, next} -> {:cont, {:noreply, next}}
      :closed -> {:halt, {:stop, :normal, current}}
    end
  end

  defp write(state, frame) do
    with {:ok, websocket, encoded} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.request, encoded) do
      {:ok, %{state | conn: conn, websocket: websocket}}
    else
      _closed -> :closed
    end
  end

  defp open(options) do
    case options.connector.(options) do
      {:ok, conn, scheme} ->
        case Mint.WebSocket.upgrade(scheme, conn, options.path, Secret.reveal(options.headers)) do
          {:ok, conn, request} ->
            handshake(conn, request, System.monotonic_time(:millisecond) + 10_000, %{
              status: nil,
              headers: [],
              body: "",
              done: false
            })

          {:error, conn, _reason} ->
            Mint.HTTP.close(conn)
            {:error, :provider_unavailable}
        end

      _unavailable ->
        {:error, :provider_unavailable}
    end
  end

  defp provider_connection(options) do
    with {:ok, conn} <-
           Mint.HTTP.connect(:https, options.host, 443,
             protocols: [:http1],
             transport_opts: [timeout: 10_000, cacerts: :public_key.cacerts_get()]
           ) do
      {:ok, conn, :wss}
    end
  end

  defp handshake(conn, request, deadline, response) do
    socket = Mint.HTTP.get_socket(conn)

    receive do
      {kind, ^socket, _data} = message when kind in [:ssl, :tcp, :ssl_error, :tcp_error] ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, events} ->
            case collect(events, request, response) do
              {:ok, %{done: true, status: 101} = response} ->
                case Mint.WebSocket.new(conn, request, 101, response.headers) do
                  {:ok, conn, websocket} ->
                    {:ok, conn, request, websocket, response.body}

                  {:error, conn, _reason} ->
                    Mint.HTTP.close(conn)
                    {:error, :provider_unavailable}
                end

              {:ok, %{done: true} = response} ->
                Mint.HTTP.close(conn)
                {:error, {:provider_response, response.status, response.headers, response.body}}

              {:ok, response} ->
                handshake(conn, request, deadline, response)

              :invalid ->
                Mint.HTTP.close(conn)
                {:error, :provider_unavailable}
            end

          _error ->
            Mint.HTTP.close(conn)
            {:error, :provider_unavailable}
        end
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        Mint.HTTP.close(conn)
        {:error, :provider_unavailable}
    end
  end

  defp collect(events, request, response) do
    Enum.reduce_while(events, {:ok, response}, fn
      {:status, ^request, status}, {:ok, response} ->
        {:cont, {:ok, %{response | status: status}}}

      {:headers, ^request, headers}, {:ok, response} ->
        {:cont, {:ok, %{response | headers: response.headers ++ headers}}}

      {:data, ^request, bytes}, {:ok, response}
      when byte_size(response.body) + byte_size(bytes) <= 1_048_576 ->
        {:cont, {:ok, %{response | body: response.body <> bytes}}}

      {:done, ^request}, {:ok, response} ->
        {:cont, {:ok, %{response | done: true}}}

      _invalid, _response ->
        {:halt, :invalid}
    end)
  end
end
