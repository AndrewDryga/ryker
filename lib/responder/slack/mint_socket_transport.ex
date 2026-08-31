defmodule Responder.Slack.MintSocketTransport do
  @moduledoc """
  Slack Socket Mode transport backed by Mint and `Mint.WebSocket`.

  The short-lived WSS URL is fetched with the configured Slack app token. It
  is kept only in process memory and is never logged or persisted.
  """

  @behaviour Responder.Slack.SocketTransport

  @fields [:handshake_timeout_ms, :http, :mint_http, :mint_websocket, :requester]
  @default_handshake_timeout_ms 10_000

  @impl true
  def connect(options) do
    with {:ok, options} <- options(options),
         {:ok, url} <- open_url(options),
         {:ok, target} <- connection_target(url),
         {:ok, conn} <- connect_http(target, options),
         {:ok, conn, request_ref} <- upgrade(conn, target, options),
         {:ok, conn, websocket} <-
           await_upgrade(conn, request_ref, options.handshake_timeout_ms, options) do
      {:ok,
       %{
         conn: conn,
         http_module: options.mint_http,
         request_ref: request_ref,
         websocket: websocket,
         websocket_module: options.mint_websocket
       }}
    end
  end

  @impl true
  def stream(%{conn: conn, websocket_module: websocket_module} = state, message) do
    case websocket_module.stream(conn, message) do
      {:ok, conn, responses} -> decode_responses(%{state | conn: conn}, responses)
      {:error, conn, reason, _responses} -> {:error, {:slack_socket_transport, reason, conn}}
      :unknown -> {:unknown, state}
    end
  end

  @impl true
  def send_frame(
        %{
          conn: conn,
          request_ref: request_ref,
          websocket: websocket,
          websocket_module: websocket_module
        } = state,
        frame
      ) do
    with {:ok, websocket, data} <- websocket_module.encode(websocket, frame),
         {:ok, conn} <- websocket_module.stream_request_body(conn, request_ref, data) do
      {:ok, %{state | conn: conn, websocket: websocket}}
    else
      {:error, _state, reason} -> {:error, {:slack_socket_transport, reason}}
    end
  end

  @impl true
  def close(%{conn: conn, http_module: http_module} = state) do
    _result = send_frame(state, :close)
    http_module.close(conn)
  end

  @doc false
  @spec connection_target(String.t()) :: {:ok, map()} | {:error, term()}
  def connection_target(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{
        scheme: "wss",
        host: host,
        path: path,
        query: query,
        fragment: nil,
        userinfo: nil
      } = uri
      when is_binary(host) and host != "" ->
        validate_connection_target(uri, url, host, request_path(path, query))

      _invalid ->
        {:error, {:invalid_slack_socket_url, :url}}
    end
  end

  def connection_target(_url), do: {:error, {:invalid_slack_socket_url, :url}}

  defp validate_connection_target(uri, url, host, request_path) do
    if String.valid?(url) and byte_size(url) <= 8_192 and slack_socket_host?(host) and
         (uri.port || 443) == 443 and valid_request_path?(request_path) do
      {:ok, %{host: String.downcase(host), path: request_path, port: 443}}
    else
      {:error, {:invalid_slack_socket_url, :url}}
    end
  end

  defp slack_socket_host?(host) do
    host = String.downcase(host)
    host != "slack.com" and String.ends_with?(host, ".slack.com")
  end

  defp open_url(options) do
    case options.requester.request(options.http, :post, "/apps.connections.open", %{}, []) do
      {:ok, %{body: %{"ok" => true, "url" => url}, status: 200}}
      when is_binary(url) and url != "" ->
        {:ok, url}

      {:ok, %{body: %{"error" => error}, status: status}}
      when is_integer(status) and is_binary(error) ->
        {:error, {:slack_socket_open_failed, status, error}}

      {:ok, %{status: status}} when is_integer(status) ->
        {:error, {:slack_socket_open_failed, status, :invalid_response}}

      {:error, reason} ->
        {:error, reason}

      _invalid ->
        {:error, {:slack_socket_open_failed, :invalid_response}}
    end
  end

  defp connect_http(target, options) do
    options.mint_http.connect(:https, target.host, target.port,
      protocols: [:http1],
      transport_opts: [cacerts: :public_key.cacerts_get()]
    )
  end

  defp upgrade(conn, target, options) do
    case options.mint_websocket.upgrade(:wss, conn, target.path, []) do
      {:ok, conn, request_ref} ->
        {:ok, conn, request_ref}

      {:error, conn, reason} ->
        options.mint_http.close(conn)
        {:error, {:slack_socket_upgrade_failed, reason}}
    end
  end

  defp await_upgrade(conn, request_ref, timeout_ms, options) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_upgrade(conn, request_ref, deadline, nil, nil, options)
  end

  defp await_upgrade(conn, request_ref, deadline, status, headers, options) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      message ->
        case options.mint_websocket.stream(conn, message) do
          {:ok, conn, responses} ->
            case upgrade_responses(responses, request_ref, status, headers) do
              {:continue, status, headers} ->
                await_upgrade(conn, request_ref, deadline, status, headers, options)

              {:done, status, headers} ->
                finish_upgrade(conn, request_ref, status, headers, options)

              {:error, reason} ->
                options.mint_http.close(conn)
                {:error, reason}
            end

          {:error, conn, reason, _responses} ->
            options.mint_http.close(conn)
            {:error, {:slack_socket_upgrade_failed, reason}}

          :unknown ->
            await_upgrade(conn, request_ref, deadline, status, headers, options)
        end
    after
      remaining ->
        options.mint_http.close(conn)
        {:error, {:slack_socket_upgrade_failed, :timeout}}
    end
  end

  defp upgrade_responses(responses, request_ref, status, headers) do
    Enum.reduce_while(responses, {:continue, status, headers}, fn
      {:status, ^request_ref, value}, {:continue, nil, headers}
      when is_integer(value) ->
        {:cont, {:continue, value, headers}}

      {:headers, ^request_ref, value}, {:continue, status, nil} when is_list(value) ->
        {:cont, {:continue, status, value}}

      {:done, ^request_ref}, {:continue, status, headers}
      when is_integer(status) and is_list(headers) ->
        {:halt, {:done, status, headers}}

      {:error, ^request_ref, reason}, _state ->
        {:halt, {:error, {:slack_socket_upgrade_failed, reason}}}

      _unexpected, _state ->
        {:halt, {:error, {:slack_socket_upgrade_failed, :response}}}
    end)
  end

  defp finish_upgrade(conn, request_ref, status, headers, options) do
    case options.mint_websocket.new(conn, request_ref, status, headers) do
      {:ok, conn, websocket} ->
        {:ok, conn, websocket}

      {:error, conn, reason} ->
        options.mint_http.close(conn)
        {:error, {:slack_socket_upgrade_failed, reason}}
    end
  end

  defp decode_responses(state, responses) do
    Enum.reduce_while(responses, {:ok, state, []}, fn
      {:data, request_ref, data}, {:ok, %{request_ref: request_ref} = state, frames} ->
        case state.websocket_module.decode(state.websocket, data) do
          {:ok, websocket, decoded} ->
            {:cont, {:ok, %{state | websocket: websocket}, frames ++ decoded}}

          {:error, _websocket, reason} ->
            {:halt, {:error, {:slack_socket_decode_failed, reason}}}
        end

      {:error, request_ref, reason}, {:ok, %{request_ref: request_ref}, _frames} ->
        {:halt, {:error, {:slack_socket_transport, reason}}}

      _unexpected, _state ->
        {:halt, {:error, {:slack_socket_transport, :response}}}
    end)
  end

  defp options(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options),
      do: options |> Map.new() |> options(),
      else: {:error, {:invalid_slack_socket_transport, :fields}}
  end

  defp options(%{} = options) do
    options =
      options
      |> Map.put_new(:handshake_timeout_ms, @default_handshake_timeout_ms)
      |> Map.put_new(:mint_http, Mint.HTTP)
      |> Map.put_new(:mint_websocket, Mint.WebSocket)

    if valid_options?(options) do
      {:ok, options}
    else
      {:error, {:invalid_slack_socket_transport, :fields}}
    end
  end

  defp options(_options), do: {:error, {:invalid_slack_socket_transport, :fields}}

  defp valid_options?(options) do
    Enum.all?([
      Map.keys(options) |> Enum.sort() == Enum.sort(@fields),
      requester?(Map.get(options, :requester)),
      module_exports?(Map.get(options, :mint_http), connect: 4, close: 1),
      module_exports?(Map.get(options, :mint_websocket),
        decode: 2,
        encode: 2,
        new: 4,
        stream: 2,
        stream_request_body: 3,
        upgrade: 4
      ),
      valid_handshake_timeout?(Map.get(options, :handshake_timeout_ms))
    ])
  end

  defp requester?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :request, 5)
  end

  defp requester?(_module), do: false

  defp valid_handshake_timeout?(timeout_ms) do
    is_integer(timeout_ms) and timeout_ms >= 100 and timeout_ms <= 60_000
  end

  defp module_exports?(module, callbacks) when is_atom(module) and is_list(callbacks) do
    Code.ensure_loaded?(module) and
      Enum.all?(callbacks, fn {function, arity} -> function_exported?(module, function, arity) end)
  end

  defp module_exports?(_module, _callbacks), do: false

  defp request_path(nil, nil), do: "/"
  defp request_path(nil, query), do: "/?" <> query
  defp request_path(path, nil), do: path
  defp request_path(path, query), do: path <> "?" <> query

  defp valid_request_path?(path) do
    is_binary(path) and String.starts_with?(path, "/") and String.valid?(path) and
      byte_size(path) <= 8_192
  end
end
