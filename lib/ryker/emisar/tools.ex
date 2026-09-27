defmodule Ryker.Emisar.Tools do
  @moduledoc """
  Emisar's own tools for Work, with the key of the session's environment.

  Work sessions were never given them: they were expected from an MCP server
  on the Coop worker, which the bundled worker never had (2026-09-27, when
  Ryker told Andrew that only the approval receipt was there). Ryker now
  offers them through its state tools (`Ryker.StateTools.Router`): it reads
  the tools and instructions Emisar gives the environment's key
  (`initialize`, `tools/list`), offers exactly those, and forwards each call
  (`tools/call`), returning Emisar's answer as it came. Emisar's policy
  decides what the key may do; Ryker adds no permission of its own.

  The key goes to Emisar in the authorization header and nowhere else. An
  answer that carries it is withheld rather than shown to the model.

  A tool Emisar does not mark read-only is a mutation. Ryker names each
  mutation's operation before sending it, so when the answer is lost the
  model is told which operation to look up instead of sending it again, as
  Emisar asks.
  """

  import Bitwise

  alias Ryker.Credentials
  alias Ryker.Delivery.JSONClient
  alias Ryker.Emisar.ToolCache

  @protocol_version "2025-11-25"
  @headers [
    {"accept", "application/json, text/event-stream"},
    {"mcp-protocol-version", @protocol_version},
    {"user-agent", "ryker"}
  ]

  # A catalog is read again after five minutes, or at once when the key or
  # address changes. A failure is remembered briefly, so a session start does
  # not wait on an Emisar that just refused or did not answer.
  @catalog_ttl_ms 5 * 60 * 1_000
  @failure_ttl_ms 30 * 1_000

  # Emisar's wait_for_run blocks for up to 60 seconds before it answers.
  @call_timeout_ms 60_000

  # The catalog is read while the model's client starts Ryker's tool server,
  # which it gives up on after ten seconds (Codex). An Emisar that has not
  # answered both reads within this budget, however its connection hangs, is
  # unavailable for now: the session keeps every Ryker tool.
  @catalog_budget_ms 4_000

  @maximum_tools 64
  @maximum_instruction_bytes 16_384
  @alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"

  # Refusals that mean the request never left Ryker, so nothing ran.
  @never_sent [:econnrefused, :nxdomain, :ehostunreach, :enetunreach, :eaddrnotavail]

  @type pin :: %{connection_ref: String.t(), account_ref: String.t(), rpc_url: String.t()}
  @type catalog :: %{tools: [map()], instructions: String.t() | nil}
  @type failure :: :not_configured | :key_refused | :unavailable

  @doc "The tools and instructions Emisar gives the environment's key."
  @spec catalog(pin()) :: {:ok, catalog()} | {:error, failure()}
  def catalog(%{connection_ref: ref, rpc_url: url}) when is_binary(ref) and is_binary(url) do
    with {:ok, key} <- key(ref),
         {:ok, client} <- client(url, key, catalog_budget_ms()),
         do: cached_catalog({ref, url, fingerprint(key)}, client)
  end

  def catalog(_pin), do: {:error, :not_configured}

  defp cached_catalog(cache_key, client) do
    case ToolCache.get(cache_key) do
      {:ok, answer} -> answer
      :miss -> remember(cache_key, bounded_read(client))
    end
  end

  defp bounded_read(client) do
    task = Task.async(fn -> safe_read(client) end)

    case Task.yield(task, catalog_budget_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, answer} -> answer
      _late -> {:error, :unavailable}
    end
  end

  # The read runs linked to the tool server's request: a raise in it must be
  # an unavailable Emisar, not a failed request.
  defp safe_read(client) do
    read_catalog(client)
  rescue
    _error -> {:error, :unavailable}
  end

  defp catalog_budget_ms,
    do: Application.get_env(:ryker, :emisar_catalog_budget_ms, @catalog_budget_ms)

  defp remember(cache_key, answer) do
    ttl = if match?({:ok, _catalog}, answer), do: @catalog_ttl_ms, else: @failure_ttl_ms
    :ok = ToolCache.put(cache_key, answer, ttl)
    answer
  end

  @doc "Whether Emisar marks the tool as one that changes nothing."
  @spec read_only?(map()) :: boolean()
  def read_only?(%{"annotations" => %{"readOnlyHint" => true}}), do: true
  def read_only?(_tool), do: false

  @doc """
  Sends one call to Emisar and returns its answer unchanged: the MCP tool
  result, `isError` and all, since Emisar's refusal is Emisar's to word.
  """
  @spec call(pin(), map(), term()) ::
          {:ok, map()}
          | {:error,
             failure()
             | :answer_withheld
             | {:no_answer, String.t()}
             | {:rejected, String.t()}}
  def call(%{connection_ref: ref, rpc_url: url}, %{"name" => name} = tool, arguments)
      when is_binary(ref) and is_binary(url) and is_binary(name) do
    operation_id = if read_only?(tool), do: nil, else: operation_id()
    request = rpc("tools/call", %{"arguments" => arguments, "name" => name})

    with {:ok, key} <- key(ref),
         {:ok, client} <- client(url, key, @call_timeout_ms) do
      client
      |> post(request, call_headers(operation_id))
      |> call_answer(key, operation_id)
    end
  end

  def call(_pin, _tool, _arguments), do: {:error, :not_configured}

  defp call_headers(nil), do: @headers
  defp call_headers(operation_id), do: [{"emisar-operation-id", operation_id} | @headers]

  defp call_answer({:ok, %{"result" => %{} = result}}, key, _operation_id),
    do: withheld_or(result, key, {:ok, result})

  # Emisar read the request and refused its shape before running anything.
  defp call_answer({:ok, %{"error" => %{"code" => code, "message" => message}}}, key, _operation)
       when code in [-32_600, -32_601, -32_602] and is_binary(message),
       do: withheld_or(message, key, {:error, {:rejected, String.slice(message, 0, 500)}})

  defp call_answer({:error, :key_refused}, _key, _operation_id), do: {:error, :key_refused}
  defp call_answer({:error, :never_sent}, _key, _operation_id), do: {:error, :unavailable}

  # Anything else may have happened after Emisar received the request.
  defp call_answer(_no_answer, _key, nil), do: {:error, :unavailable}
  defp call_answer(_no_answer, _key, operation_id), do: {:error, {:no_answer, operation_id}}

  defp withheld_or(answer, key, result) do
    if String.contains?(Jason.encode!(answer), key), do: {:error, :answer_withheld}, else: result
  end

  defp read_catalog(client) do
    with {:ok, %{"result" => %{} = initialized}} <-
           post(client, rpc("initialize", initialize_params()), @headers),
         {:ok, %{"result" => %{"tools" => tools}}} when is_list(tools) <-
           post(client, rpc("tools/list", %{}), @headers),
         {:ok, tools} <- tools(tools) do
      {:ok, %{tools: tools, instructions: instructions(initialized["instructions"])}}
    else
      {:error, :key_refused} -> {:error, :key_refused}
      _unavailable -> {:error, :unavailable}
    end
  end

  defp tools(tools) when length(tools) <= @maximum_tools do
    if Enum.all?(tools, &tool?/1) and Enum.uniq_by(tools, & &1["name"]) == tools,
      do: {:ok, tools},
      else: {:error, :unavailable}
  end

  defp tools(_tools), do: {:error, :unavailable}

  defp tool?(%{"name" => name, "inputSchema" => %{}}),
    do: is_binary(name) and byte_size(name) in 1..128

  defp tool?(_tool), do: false

  defp instructions(text) when is_binary(text) and byte_size(text) <= @maximum_instruction_bytes,
    do: text

  defp instructions(_text), do: nil

  defp initialize_params do
    %{
      "capabilities" => %{},
      "clientInfo" => %{"name" => "ryker", "version" => "1"},
      "protocolVersion" => @protocol_version
    }
  end

  defp rpc(method, params),
    do: %{
      "id" => "ryker-" <> random_ref(),
      "jsonrpc" => "2.0",
      "method" => method,
      "params" => params
    }

  # Emisar answers a key it refuses with HTTP 401 (-32001) and a key of
  # another kind, such as an audit export key, with -32002.
  defp post(client, request, headers) do
    case requester().request(client.http, :post, client.path, request, headers) do
      {:ok, %{status: 200, body: %{"error" => %{"code" => code}}}}
      when code in [-32_001, -32_002] ->
        {:error, :key_refused}

      {:ok, %{status: 200, body: %{} = body}} ->
        {:ok, body}

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, :key_refused}

      {:ok, _response} ->
        {:error, :no_answer}

      {:error, reason} ->
        if never_sent?(reason), do: {:error, :never_sent}, else: {:error, :no_answer}
    end
  end

  defp never_sent?({:delivery_credentials_unavailable, _reason}), do: true

  defp never_sent?({:delivery_transport_unavailable, %{reason: reason}}),
    do: reason in @never_sent

  defp never_sent?({:invalid_delivery_json_request, _field}), do: true
  defp never_sent?(_reason), do: false

  defp requester, do: Application.get_env(:ryker, :emisar_requester, JSONClient)

  defp key(ref) do
    case Credentials.fetch(:emisar, ref) do
      {:ok, key} when is_binary(key) and key != "" -> {:ok, key}
      _missing -> {:error, :not_configured}
    end
  end

  defp client(url, key, timeout) do
    with %URI{scheme: "https", host: host, path: path, userinfo: nil, query: nil, fragment: nil} =
           uri
         when is_binary(host) and host != "" and is_binary(path) and path != "" <- URI.parse(url),
         origin = uri |> Map.put(:path, nil) |> URI.to_string(),
         {:ok, http} <-
           JSONClient.new(%{
             base_url: origin,
             finch: Ryker.CoopFinch,
             receive_timeout: timeout,
             token_provider: fn -> {:ok, key} end
           }) do
      {:ok, %{http: http, path: path}}
    else
      _invalid -> {:error, :not_configured}
    end
  end

  defp fingerprint(key), do: :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)

  defp random_ref, do: :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)

  # An `op_` ULID, the form Emisar accepts: 48 bits of time, 80 of chance.
  defp operation_id do
    <<value::unsigned-integer-size(128)>> =
      <<System.system_time(:millisecond)::unsigned-integer-size(48),
        :crypto.strong_rand_bytes(10)::binary>>

    "op_" <>
      for(shift <- 25..0//-1, into: "", do: <<Enum.at(@alphabet, value >>> (5 * shift) &&& 31)>>)
  end
end
