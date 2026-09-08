defmodule Responder.StateTools.Router do
  @moduledoc """
  Stateless, authenticated MCP endpoint for inert episode state tools.

  The transport bearer authenticates the trusted Coop daemon. Every mutating
  tool additionally requires the opaque active-turn capability carried in the
  frozen work context.
  """

  @behaviour Plug

  import Plug.Conn

  alias Responder.CanonicalJSON
  alias Responder.StateTools.{Tools, ToolVisibility}

  @maximum_body_bytes 1_048_576
  @protocol_version "2025-11-25"

  @impl Plug
  def init(options) do
    token = Keyword.fetch!(options, :token)
    cursor_secret = Keyword.get(options, :cursor_secret, token)
    binding = Keyword.get(options, :binding)
    emisar_rpc_url = Keyword.get(options, :emisar_rpc_url)

    capabilities =
      Keyword.get(options, :capabilities, [:event_waits, :publication, :schedules])

    additional_tools = Keyword.get(options, :additional_tools, [])
    additional_call = Keyword.get(options, :additional_call)

    unless valid_token?(token),
      do: raise(ArgumentError, "state-tools token must be at least 16 valid UTF-8 bytes")

    unless is_nil(cursor_secret) or valid_token?(cursor_secret),
      do: raise(ArgumentError, "memory cursor secret must be at least 16 valid UTF-8 bytes")

    unless is_nil(emisar_rpc_url) or valid_emisar_rpc_url?(emisar_rpc_url),
      do: raise(ArgumentError, "state-tools Emisar RPC URL must be an HTTPS URL")

    unless valid_capabilities?(capabilities),
      do: raise(ArgumentError, "state-tools capabilities must be unique known atoms")

    validate_additional_tools!(additional_tools, additional_call, capabilities, emisar_rpc_url)

    %{
      additional_call: additional_call,
      additional_tools: additional_tools,
      binding: binding,
      capabilities: capabilities,
      cursor_secret: cursor_secret,
      emisar_rpc_url: emisar_rpc_url,
      token: token
    }
  end

  @impl Plug
  def call(%Plug.Conn{method: "POST", path_info: ["mcp"]} = conn, options) do
    with :ok <- authorize(conn, options.token),
         :ok <- json_content_type(conn),
         {:ok, body, conn} <- read_request_body(conn),
         {:ok, request} <- decode_request(body) do
      respond_rpc(conn, request, options)
    else
      {:error, :unauthorized} ->
        respond(conn, 401, %{"error" => "unauthorized"})

      {:error, :unsupported_media_type} ->
        respond(conn, 415, %{"error" => "unsupported_media_type"})

      {:error, :too_large} ->
        respond(conn, 413, %{"error" => "payload_too_large"})

      {:error, :invalid_request} ->
        rpc_error(conn, nil, -32_600, "Invalid Request")
    end
  end

  def call(conn, _options), do: respond(conn, 404, %{"error" => "not_found"})

  defp respond_rpc(
         conn,
         %{
           "id" => id,
           "jsonrpc" => "2.0",
           "method" => "initialize",
           "params" => %{} = params
         },
         _options
       ) do
    version =
      case params["protocolVersion"] do
        value when is_binary(value) and value != "" -> value
        _missing -> @protocol_version
      end

    rpc_result(conn, id, %{
      "capabilities" => %{"tools" => %{"listChanged" => false}},
      "protocolVersion" => version,
      "serverInfo" => %{"name" => "responder-state", "version" => "1"}
    })
  end

  defp respond_rpc(
         conn,
         %{
           "id" => id,
           "jsonrpc" => "2.0",
           "method" => "tools/list",
           "params" => %{}
         },
         options
       ),
       do:
         rpc_result(conn, id, %{
           "tools" => Tools.list(options) ++ visible_additional_tools(options)
         })

  defp respond_rpc(
         conn,
         %{
           "id" => id,
           "jsonrpc" => "2.0",
           "method" => "tools/call",
           "params" => %{"arguments" => arguments, "name" => name}
         },
         options
       ) do
    case call_tool(name, arguments, options) do
      {:ok, result} -> rpc_result(conn, id, tool_result(result, false))
      {:error, error} -> rpc_result(conn, id, tool_result(%{"error" => error}, true))
    end
  end

  defp respond_rpc(
         conn,
         %{
           "id" => id,
           "jsonrpc" => "2.0",
           "method" => "ping",
           "params" => %{}
         },
         _options
       ),
       do: rpc_result(conn, id, %{})

  defp respond_rpc(
         conn,
         %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
         _options
       ) do
    conn |> send_resp(202, "") |> halt()
  end

  defp respond_rpc(conn, %{"id" => id}, _options),
    do: rpc_error(conn, id, -32_601, "Method not found")

  defp respond_rpc(conn, _request, _options),
    do: rpc_error(conn, nil, -32_600, "Invalid Request")

  defp tool_result(result, is_error) do
    %{
      "content" => [%{"text" => CanonicalJSON.encode!(result), "type" => "text"}],
      "isError" => is_error,
      "structuredContent" => result
    }
  end

  defp call_tool(name, arguments, options) do
    cond do
      Enum.any?(Tools.list(options), &(&1["name"] == name)) ->
        Tools.call(name, arguments, options)

      Enum.any?(visible_additional_tools(options), &(&1["name"] == name)) ->
        case call_additional(options.additional_call, name, arguments, options.binding) do
          {:ok, %{} = result} -> {:ok, result}
          {:error, error} when is_binary(error) or is_map(error) -> {:error, error}
          _invalid -> {:error, "invalid_fabricated_tool_response"}
        end

      true ->
        {:error, "unknown_tool"}
    end
  end

  defp call_additional(callback, name, arguments, binding) when is_function(callback, 3),
    do: callback.(name, arguments, binding)

  defp call_additional(callback, name, arguments, _binding) when is_function(callback, 2),
    do: callback.(name, arguments)

  defp visible_additional_tools(options) do
    transport =
      case options.binding do
        %{episode: %{destination_transport: value}} when is_binary(value) -> value
        _unbound_or_synthetic -> nil
      end

    Enum.filter(options.additional_tools, fn tool ->
      ToolVisibility.visible?(tool["name"], transport)
    end)
  end

  defp authorize(conn, token) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> supplied] when byte_size(supplied) == byte_size(token) ->
        if Plug.Crypto.secure_compare(supplied, token),
          do: :ok,
          else: {:error, :unauthorized}

      _other ->
        {:error, :unauthorized}
    end
  end

  defp json_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [value] ->
        if String.downcase(value) |> String.starts_with?("application/json"),
          do: :ok,
          else: {:error, :unsupported_media_type}

      _other ->
        {:error, :unsupported_media_type}
    end
  end

  defp read_request_body(conn, bytes \\ "") do
    case Plug.Conn.read_body(conn, length: @maximum_body_bytes + 1, read_length: 64 * 1_024) do
      {:ok, body, conn} -> bounded_body(bytes <> body, conn)
      {:more, body, conn} -> continue_body(bytes <> body, conn)
      {:error, _reason} -> {:error, :invalid_request}
    end
  end

  defp continue_body(bytes, _conn) when byte_size(bytes) > @maximum_body_bytes,
    do: {:error, :too_large}

  defp continue_body(bytes, conn), do: read_request_body(conn, bytes)

  defp bounded_body(bytes, _conn) when byte_size(bytes) > @maximum_body_bytes,
    do: {:error, :too_large}

  defp bounded_body(bytes, conn), do: {:ok, bytes, conn}

  defp decode_request(body) do
    case Jason.decode(body) do
      {:ok, %{} = request} -> {:ok, request}
      _invalid -> {:error, :invalid_request}
    end
  end

  defp rpc_result(conn, id, result),
    do: respond(conn, 200, %{"id" => id, "jsonrpc" => "2.0", "result" => result})

  defp rpc_error(conn, id, code, message) do
    respond(conn, 200, %{
      "error" => %{"code" => code, "message" => message},
      "id" => id,
      "jsonrpc" => "2.0"
    })
  end

  defp respond(conn, status, document) do
    body = Jason.encode!(document)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end

  defp valid_token?(token) do
    is_binary(token) and String.valid?(token) and byte_size(token) >= 16 and
      :binary.match(token, <<0>>) == :nomatch
  end

  defp validate_additional_tools!(tools, callback, capabilities, emisar_rpc_url)
       when is_list(tools) and length(tools) <= 128 do
    production_names =
      Tools.list(capabilities: capabilities, emisar_rpc_url: emisar_rpc_url)
      |> MapSet.new(& &1["name"])

    names = Enum.map(tools, & &1["name"])

    valid? =
      Enum.all?([
        Enum.all?(tools, &valid_additional_tool?/1),
        Enum.uniq(names) == names,
        MapSet.disjoint?(production_names, MapSet.new(names)),
        valid_additional_callback?(tools, callback)
      ])

    unless valid? do
      raise ArgumentError,
            "additional state-tools must be unique valid schemas, include a callback, and never collide with production tools"
    end
  end

  defp validate_additional_tools!(_tools, _callback, _capabilities, _emisar_rpc_url) do
    raise ArgumentError, "additional state-tools are invalid"
  end

  defp valid_additional_callback?([], callback), do: is_nil(callback)

  defp valid_additional_callback?([_first | _rest], callback),
    do: is_function(callback, 2) or is_function(callback, 3)

  defp valid_additional_tool?(
         %{
           "description" => description,
           "inputSchema" => %{} = schema,
           "name" => name
         } = tool
       )
       when map_size(tool) == 3 and is_binary(description) and description != "" and
              byte_size(description) <= 2_048 and is_binary(name) and name != "" and
              byte_size(name) <= 256 do
    CanonicalJSON.validate(schema, max_bytes: 64 * 1_024) == :ok
  end

  defp valid_additional_tool?(_tool), do: false

  defp valid_emisar_rpc_url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil} ->
        is_binary(host) and host != ""

      _invalid ->
        false
    end
  end

  defp valid_emisar_rpc_url?(_value), do: false

  defp valid_capabilities?(capabilities) when is_list(capabilities) do
    capabilities == Enum.uniq(capabilities) and
      Enum.all?(
        capabilities,
        &(&1 in [:emisar_approvals, :event_waits, :publication, :schedules])
      )
  end

  defp valid_capabilities?(_capabilities), do: false
end
