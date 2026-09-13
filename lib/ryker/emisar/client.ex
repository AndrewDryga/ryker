defmodule Ryker.Emisar.Client do
  @moduledoc """
  Bounded MCP client for the single read-only `wait_for_run` operation.

  Credentials and the exact RPC endpoint come from trusted runtime
  configuration. Run URLs are accepted only from that same HTTPS origin.
  """

  @behaviour Ryker.Emisar.API

  alias Ryker.Emisar.{Review, RunState}

  @fields [:http, :requester, :rpc_path, :rpc_origin]
  @headers [
    {"accept", "application/json, text/event-stream"},
    {"mcp-protocol-version", "2025-11-25"},
    {"user-agent", "ryker"}
  ]
  @maximum_error_bytes 1_000
  @maximum_reference_bytes 300

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          http: term(),
          requester: module(),
          rpc_origin: String.t(),
          rpc_path: String.t()
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attributes) do
    with {:ok, attributes} <- normalize(attributes),
         client <- struct!(__MODULE__, attributes),
         true <- requester?(client.requester),
         :ok <- origin(client.rpc_origin),
         :ok <- path(client.rpc_path) do
      {:ok, client}
    else
      false -> {:error, {:invalid_emisar_client, :requester}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def wait_for_run(%__MODULE__{} = client, run_id) do
    with :ok <- reference(run_id, 200, :run_id),
         {:ok, response} <-
           client.requester.request(
             client.http,
             :post,
             client.rpc_path,
             request_document(run_id),
             @headers
           ),
         {:ok, structured} <- response_document(response) do
      run_state(structured, client.rpc_origin)
    end
  end

  def wait_for_run(_client, _run_id), do: {:error, {:invalid_emisar_client, :client}}

  defp request_document(run_id) do
    digest = :crypto.hash(:sha256, run_id) |> Base.encode16(case: :lower)

    %{
      "id" => "ryker-wait-for-run-#{digest}",
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "params" => %{
        "arguments" => %{"run_id" => run_id, "timeout" => "0"},
        "name" => "wait_for_run"
      }
    }
  end

  defp response_document(%{
         body: %{
           "id" => id,
           "jsonrpc" => "2.0",
           "result" => %{
             "isError" => false,
             "structuredContent" => %{} = structured
           }
         },
         status: 200
       })
       when is_binary(id),
       do: {:ok, structured}

  defp response_document(%{
         body: %{
           "error" => %{"code" => code, "message" => message},
           "jsonrpc" => "2.0"
         },
         status: 200
       })
       when is_integer(code) and is_binary(message),
       do: {:error, {:emisar_rpc_error, code, bounded(message, @maximum_error_bytes)}}

  defp response_document(%{body: body, status: status}) when is_integer(status) and status >= 400,
    do: {:error, {:emisar_http_error, status, bounded(inspect(body), @maximum_error_bytes)}}

  defp response_document(_response), do: {:error, {:emisar_protocol_error, :response}}

  defp run_state(%{"ok" => true, "run" => %{} = run}, origin) do
    with :ok <- reference(run["run_id"], 200, :run_id),
         :ok <- reference(run["operation_id"], 200, :operation_id),
         :ok <- reference(run["action_id"], 200, :action_id),
         :ok <- reference(run["pack_ref"], @maximum_reference_bytes, :pack_ref),
         :ok <- reference(run["runner_ref"], @maximum_reference_bytes, :runner_ref),
         true <- RunState.valid_status?(run["status"]),
         {:ok, run_url} <- optional_same_origin_url(run["run_url"], origin),
         {:ok, error_message} <- optional_text(run["error_message"], @maximum_error_bytes),
         {:ok, review} <- review(run["review"]) do
      {:ok,
       %RunState{
         action_id: run["action_id"],
         error_message: error_message,
         operation_id: run["operation_id"],
         pack_ref: run["pack_ref"],
         review: review,
         run_id: run["run_id"],
         run_url: run_url,
         runner_ref: run["runner_ref"],
         status: run["status"]
       }}
    else
      false -> {:error, {:emisar_protocol_error, :status}}
      {:error, _reason} = error -> error
    end
  end

  defp run_state(%{"error" => %{"code" => code, "message" => message}, "ok" => false}, _origin)
       when is_binary(code) and is_binary(message),
       do: {:error, {:emisar_tool_error, code, bounded(message, @maximum_error_bytes)}}

  defp run_state(_structured, _origin), do: {:error, {:emisar_protocol_error, :run}}

  # The review receipt is Emisar's, so a shape this host cannot validate is a
  # protocol error rather than a card rendered from a document nobody checked.
  defp review(value) do
    case Review.prepare(value) do
      {:ok, review} -> {:ok, review}
      {:error, _reason} -> {:error, {:emisar_protocol_error, :review}}
    end
  end

  defp optional_same_origin_url(nil, _origin), do: {:ok, nil}
  defp optional_same_origin_url("", _origin), do: {:ok, nil}

  defp optional_same_origin_url(value, origin) when is_binary(value) do
    with %URI{scheme: "https", host: host, port: port, userinfo: nil, query: nil, fragment: nil} =
           uri <- URI.parse(value),
         true <- is_binary(host) and host != "",
         %URI{scheme: "https", host: expected_host, port: expected_port} <- URI.parse(origin),
         true <-
           String.downcase(host) == String.downcase(expected_host) and
             effective_port(port) == effective_port(expected_port) do
      {:ok, URI.to_string(uri)}
    else
      _invalid -> {:error, {:emisar_protocol_error, :run_url}}
    end
  end

  defp optional_same_origin_url(_value, _origin),
    do: {:error, {:emisar_protocol_error, :run_url}}

  defp optional_text(nil, _maximum), do: {:ok, nil}
  defp optional_text("", _maximum), do: {:ok, nil}

  defp optional_text(value, maximum) do
    case reference(value, maximum, :error_message) do
      :ok -> {:ok, value}
      {:error, _reason} = error -> error
    end
  end

  defp normalize(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes),
       do: attributes |> Map.new() |> normalize(),
       else: {:error, {:invalid_emisar_client, :fields}}
  end

  defp normalize(%{} = attributes) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(@fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_emisar_client, :fields}}
  end

  defp normalize(_attributes), do: {:error, {:invalid_emisar_client, :fields}}

  defp requester?(requester) do
    is_atom(requester) and Code.ensure_loaded?(requester) and
      function_exported?(requester, :request, 5)
  end

  defp origin(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, path: path, userinfo: nil, query: nil, fragment: nil}
      when is_binary(host) and host != "" and path in [nil, ""] ->
        :ok

      _invalid ->
        {:error, {:invalid_emisar_client, :rpc_origin}}
    end
  end

  defp origin(_value), do: {:error, {:invalid_emisar_client, :rpc_origin}}

  defp path(value) do
    if is_binary(value) and String.starts_with?(value, "/") and
         not String.starts_with?(value, "//") and byte_size(value) <= 2_048,
       do: :ok,
       else: {:error, {:invalid_emisar_client, :rpc_path}}
  end

  defp reference(value, maximum, field) do
    if is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
         :binary.match(value, <<0>>) == :nomatch and String.trim(value) != "",
       do: :ok,
       else: {:error, {:emisar_protocol_error, field}}
  end

  defp effective_port(nil), do: 443
  defp effective_port(port), do: port

  defp bounded(value, maximum) when is_binary(value) do
    if byte_size(value) <= maximum, do: value, else: String.byte_slice(value, 0, maximum)
  end
end
