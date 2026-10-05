defmodule Ryker.StateTools.Router do
  @moduledoc """
  The MCP endpoint for a Work turn's state tools.

  `Ryker.CoopFleet.Router` serves it at `/v1/state-tools/mcp` and has already
  resolved the request's bearer, the active turn's capability, to the turn's
  binding, so every call here acts for that one turn.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Ryker.{CanonicalJSON, Secret}
  alias Ryker.Emisar.Tools, as: EmisarTools
  alias Ryker.HTTPConnection
  alias Ryker.StateTools.{CallLog, LookupContext, Tools, ToolVisibility}

  @maximum_body_bytes 1_048_576
  @protocol_version "2025-11-25"
  # The MCP versions whose initialize, tools/list, tools/call and ping this
  # server answers alike.
  @protocol_versions ~w(2024-11-05 2025-03-26 2025-06-18 2025-11-25)

  @impl Plug
  def init(options) do
    cursor_secret = Keyword.get(options, :cursor_secret)
    binding = Keyword.get(options, :binding)

    capabilities =
      Keyword.get(options, :capabilities, [:event_waits, :publication, :schedules])

    additional_tools = Keyword.get(options, :additional_tools, [])
    additional_call = Keyword.get(options, :additional_call)
    answer_authorizer = Keyword.get(options, :answer_authorizer)

    unless is_nil(answer_authorizer) or is_function(answer_authorizer, 1),
      do: raise(ArgumentError, "answer authorizer must be a trusted one-argument function")

    unless is_nil(cursor_secret) or sealed_secret?(cursor_secret),
      do:
        raise(ArgumentError, "memory cursor secret must be at least 16 valid UTF-8 bytes, sealed")

    unless valid_capabilities?(capabilities),
      do: raise(ArgumentError, "state-tools capabilities must be unique known atoms")

    validate_additional_tools!(additional_tools, additional_call, capabilities)

    %{
      additional_call: additional_call,
      additional_tools: additional_tools,
      answer_authorizer: answer_authorizer,
      binding: binding,
      capabilities: capabilities,
      cursor_secret: cursor_secret
    }
  end

  # The cursor secret stays sealed (`Ryker.Secret`) in the options and is
  # opened only where a tool signs with it.
  @impl Plug
  def call(conn, options),
    do: conn |> HTTPConnection.close_after_refusal() |> route(options)

  defp sealed_secret?(%Secret{value: value}), do: valid_secret?(value)
  defp sealed_secret?(_secret), do: false

  defp route(%Plug.Conn{method: "POST", path_info: ["mcp"]} = conn, options) do
    with :ok <- json_content_type(conn),
         {:ok, body, conn} <- read_request_body(conn) do
      # A JSON-RPC error is a 200 that keeps the connection open, so it goes
      # out through the conn that read the body (see Ryker.HTTPConnection).
      case decode_request(body) do
        {:ok, request} -> respond_rpc(conn, with_params(request), options)
        {:error, :invalid_request} -> rpc_error(conn, nil, -32_600, "Invalid Request")
      end
    else
      {:error, :unsupported_media_type} ->
        respond(conn, 415, %{"error" => "unsupported_media_type"})

      {:error, :too_large} ->
        respond(conn, 413, %{"error" => "payload_too_large"})

      {:error, :unreadable_body} ->
        respond(conn, 400, %{"error" => "unreadable_body"})
    end
  end

  defp route(conn, _options), do: respond(conn, 404, %{"error" => "not_found"})

  defp respond_rpc(
         conn,
         %{
           "id" => id,
           "jsonrpc" => "2.0",
           "method" => "initialize",
           "params" => %{} = params
         },
         options
       ) do
    # A version this server speaks is answered as asked; any other gets the
    # server's own, as MCP requires.
    version =
      if params["protocolVersion"] in @protocol_versions,
        do: params["protocolVersion"],
        else: @protocol_version

    result = %{
      "capabilities" => %{"tools" => %{"listChanged" => false}},
      "protocolVersion" => version,
      "serverInfo" => %{"name" => "controller-tools", "version" => "1"}
    }

    # Emisar's own guidance for its tools, as Emisar gives it to any client.
    case emisar_catalog(options) do
      {:ok, _pin, %{instructions: text}} when is_binary(text) ->
        rpc_result(conn, id, Map.put(result, "instructions", text))

      _none ->
        rpc_result(conn, id, result)
    end
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
           "tools" =>
             Tools.list(options) ++ visible_additional_tools(options) ++ emisar_tools(options)
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
    called_at = DateTime.utc_now()
    answer = answer_tool(name, arguments, options)
    CallLog.record(options.binding, name, arguments, logged(answer), called_at)

    case answer do
      {:emisar, result} -> rpc_result(conn, id, result)
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

  # JSON-RPC leaves `params` out where a method takes none.
  defp with_params(request), do: Map.put_new(request, "params", %{})

  defp tool_result(result, is_error) do
    %{
      "content" => [%{"text" => CanonicalJSON.encode!(result), "type" => "text"}],
      "isError" => is_error,
      "structuredContent" => result
    }
  end

  # A raise inside a tool is Ryker's own error, not the model's: the call is
  # answered with internal_error, recorded like any other failed call, and the
  # log names the raise. It used to crash the request with HTTP 500 before
  # the call was recorded, so nobody could see why every memory search failed.
  defp answer_tool(name, arguments, options) do
    call_tool(name, arguments, options)
  rescue
    error ->
      Logger.error(
        "state tool #{name} raised: " <>
          Exception.format(:error, error, Enum.take(__STACKTRACE__, 5))
      )

      {:error, "internal_error"}
  end

  defp call_tool(name, arguments, options) do
    cond do
      Enum.any?(Tools.list(options), &(&1["name"] == name)) ->
        Tools.call(name, arguments, options)

      Enum.any?(visible_additional_tools(options), &(&1["name"] == name)) ->
        # Records.token/1 is a public turn locator, not a signing key. Platform
        # readers receive the same host-owned cursor secret as fixed memory tools.
        binding =
          if is_map(options.binding),
            do: Map.put(options.binding, :cursor_secret, opened(options.cursor_secret)),
            else: options.binding

        case call_additional(options.additional_call, name, arguments, binding) do
          {:ok, %{} = result} ->
            source_tools = Enum.map(visible_additional_tools(options), & &1["name"])

            LookupContext.enrich(
              name,
              arguments,
              binding,
              result,
              source_tools
            )

          {:error, error} when is_binary(error) or is_map(error) ->
            {:error, error}

          _invalid ->
            {:error, "invalid_fabricated_tool_response"}
        end

      true ->
        call_emisar(name, arguments, options)
    end
  end

  # Emisar's answer goes back as Emisar gave it; its refusal is a failed call
  # on the timeline like any other.
  defp logged({:emisar, %{"isError" => true} = result}),
    do: {:error, result["structuredContent"] || "emisar_error"}

  defp logged({:emisar, result}), do: {:ok, result}
  defp logged(answer), do: answer

  # Emisar's tools for a session whose environment has Emisar: exactly those
  # Emisar lists for the environment's key, after Ryker's own, never one that
  # shares a name with Ryker's, and in an observe-only session only those
  # Emisar marks read-only.
  defp emisar_tools(options) do
    case emisar_catalog(options) do
      {:ok, _pin, catalog} -> visible_emisar_tools(catalog, options)
      _none -> []
    end
  end

  defp visible_emisar_tools(catalog, options) do
    taken =
      MapSet.new(Tools.list(options) ++ visible_additional_tools(options), & &1["name"])

    observe_only? = match?(%{episode: %{execution_mode: :shadow}}, options.binding)

    Enum.filter(catalog.tools, fn tool ->
      not MapSet.member?(taken, tool["name"]) and
        (not observe_only? or EmisarTools.read_only?(tool))
    end)
  end

  defp emisar_catalog(options) do
    with {:ok, pin} <- Tools.emisar_pin(options),
         {:ok, catalog} <- EmisarTools.catalog(pin),
         do: {:ok, pin, catalog}
  end

  defp call_emisar(name, arguments, options) do
    with {:ok, pin} <- emisar_pin(options),
         {:ok, catalog} <- EmisarTools.catalog(pin),
         %{} = tool <- Enum.find(visible_emisar_tools(catalog, options), &(&1["name"] == name)) do
      pin |> EmisarTools.call(tool, arguments) |> emisar_answer()
    else
      :no_emisar -> {:error, "unknown_tool"}
      nil -> {:error, "unknown_tool"}
      {:error, _reason} = error -> emisar_answer(error)
    end
  end

  defp emisar_pin(options) do
    case Tools.emisar_pin(options) do
      {:ok, pin} -> {:ok, pin}
      {:error, _no_emisar} -> :no_emisar
    end
  end

  defp emisar_answer({:ok, result}), do: {:emisar, result}

  defp emisar_answer({:error, :key_refused}),
    do:
      {:error,
       "emisar_key_refused: Emisar refused the key of this conversation's environment. " <>
         "Nothing ran. A person can replace the key on Ryker's Integrations page."}

  defp emisar_answer({:error, :unavailable}),
    do:
      {:error,
       "emisar_unavailable: Ryker could not reach Emisar, so nothing ran and nothing was " <>
         "read. Say so rather than guessing what Emisar would have answered."}

  defp emisar_answer({:error, :not_configured}),
    do:
      {:error,
       "emisar_not_configured: this conversation's environment has no usable Emisar " <>
         "account, so nothing ran."}

  defp emisar_answer({:error, {:rejected, message}}),
    do: {:error, "emisar_rejected: Emisar rejected the call before running it: " <> message}

  defp emisar_answer({:error, :answer_withheld}),
    do:
      {:error,
       "emisar_answer_withheld: Emisar's answer carried the environment's key, so Ryker " <>
         "withheld it. Tell a person; do not repeat the call."}

  # Emisar: "If transport fails after a mutation may have reached Emisar,
  # recover through its operation ID; never repeat the mutation merely because
  # the response was lost."
  defp emisar_answer({:error, {:no_answer, operation_id}}),
    do:
      {:error,
       %{
         "code" => "emisar_no_answer",
         "message" =>
           "Emisar may have received this request, but its answer was lost, so it may " <>
             "have run. Do not repeat it: look the operation up with get_operation.",
         "next" => %{
           "arguments" => %{"operation_id" => operation_id},
           "tool" => "get_operation"
         },
         "operation_id" => operation_id
       }}

  defp call_additional(callback, name, arguments, binding) when is_function(callback, 3),
    do: callback.(name, arguments, binding)

  defp call_additional(callback, name, arguments, _binding) when is_function(callback, 2),
    do: callback.(name, arguments)

  defp visible_additional_tools(options) do
    {transport, mode} =
      case options.binding do
        %{episode: %{destination_transport: value, execution_mode: mode}}
        when is_binary(value) and mode in [:live, :shadow] ->
          {value, mode}

        _unbound_or_synthetic ->
          {nil, :live}
      end

    Enum.filter(options.additional_tools, fn tool ->
      ToolVisibility.visible?(tool["name"], transport, mode)
    end)
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
      {:error, _reason} -> {:error, :unreadable_body}
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

  defp valid_secret?(secret) do
    is_binary(secret) and String.valid?(secret) and byte_size(secret) >= 16 and
      :binary.match(secret, <<0>>) == :nomatch
  end

  defp validate_additional_tools!(tools, callback, capabilities)
       when is_list(tools) and length(tools) <= 128 do
    production_names =
      Tools.list(capabilities: capabilities)
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

  defp validate_additional_tools!(_tools, _callback, _capabilities) do
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

  defp valid_capabilities?(capabilities) when is_list(capabilities) do
    capabilities == Enum.uniq(capabilities) and
      Enum.all?(
        capabilities,
        &(&1 in [:emisar_approvals, :event_waits, :publication, :schedules])
      )
  end

  defp valid_capabilities?(_capabilities), do: false

  defp opened(nil), do: nil
  defp opened(%Secret{} = secret), do: Secret.reveal(secret)
end
