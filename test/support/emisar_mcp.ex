defmodule Ryker.TestSupport.EmisarMCP do
  @moduledoc """
  Emisar's MCP endpoint as it answers, harvested from emisar.dev on 2026-09-27
  and matching `dispatch/3` in the portal's mcp_rpc_controller.ex:
  `initialize` names the server and never the account behind a key, and gives
  Emisar's own instructions; `tools/list` lists the agent tools for an agent
  key; `tools/call` answers in Emisar's fixed result shape, the payload as
  structured content and as one JSON text block; a refused key gets HTTP 401
  with JSON-RPC error -32001, and a key of another kind gets -32002.
  testdata/emisar/PROVENANCE.md says where each answer came from.

  Ryker's own double once answered `initialize` with an account Emisar never
  sends, so every real Emisar key was refused with "Emisar did not say which
  account this token belongs to" while its tests passed.

  A token starting "refused-" is refused; one starting "audit-" is an
  audit-export key, which cannot run agent tools; one starting "viewer-" is an
  agent key whose account policy lets it read but not dispatch. Two stand for
  answers Emisar should never give, so Ryker's guard against them can be
  tested: an "echo-" key's calls are refused with the key in the message, and
  a "leaky-" key's instructions quote it.

  It is also the network in tests: `request/5` is the configured Emisar
  requester (config/test.exs), so no test reaches Emisar. It tells the calling
  process what it was sent. A host named unreachable.example refuses every
  connection, so nothing reaches it; one named silent.example lists its tools
  but never answers a call, which times out after the call was sent; one named
  hanging.example holds every request for ten seconds before it answers; one
  named limited.example turns every call away with HTTP 429 before Emisar
  sees it.
  """

  alias Ryker.Delivery.JSONClient

  @tools_list "testdata/emisar/tools_list.json"
  @instructions "testdata/emisar/instructions.txt"
  @find_actions "testdata/emisar/find_actions.json"
  @run_action_pending "testdata/emisar/run_action_pending_approval.json"
  @wait_for_run "test/ryker/emisar/fixtures/wait_for_run_review_v1.json"

  @spec request(JSONClient.t(), atom(), String.t(), map(), [{String.t(), String.t()}]) ::
          {:ok, map()} | {:error, term()}
  def request(%JSONClient{} = client, :post, path, body, headers) do
    host = URI.parse(client.base_url).host

    with false <- host == "unreachable.example",
         {:ok, token} <- client.token_provider.() do
      # A request made from a task is still the test's to see.
      recipient = List.first(Process.get(:"$callers", [])) || self()
      send(recipient, {:emisar_mcp, %{body: body, headers: headers, path: path, token: token}})

      # A host that never answers in the time anyone waits for it.
      # credo:disable-for-next-line Ryker.Checks.TestNoProcessSleep
      if host == "hanging.example", do: Process.sleep(10_000)

      cond do
        host == "silent.example" and body["method"] == "tools/call" ->
          {:error, {:delivery_transport_unavailable, %Mint.TransportError{reason: :timeout}}}

        host == "limited.example" and body["method"] == "tools/call" ->
          {:ok, %{body: "Too Many Requests", headers: [], status: 429}}

        true ->
          answer(body, token)
      end
    else
      true ->
        {:error, {:delivery_transport_unavailable, %Mint.TransportError{reason: :econnrefused}}}

      {:error, reason} ->
        {:error, {:delivery_credentials_unavailable, reason}}
    end
  end

  @spec answer(map(), String.t()) :: {:ok, map()}
  def answer(%{"id" => id}, "refused-" <> _token),
    do: respond(401, %{"error" => %{"code" => -32_001, "message" => "unauthorized"}}, id)

  def answer(%{"method" => "tools/call", "id" => id}, "echo-" <> _rest = token),
    do:
      respond(
        200,
        %{"error" => %{"code" => -32_602, "message" => "params refused for #{token}"}},
        id
      )

  def answer(%{"method" => "initialize", "id" => id, "params" => params}, token) do
    respond(
      200,
      %{
        "result" => %{
          "capabilities" => %{"tools" => %{"listChanged" => false}},
          "instructions" => instructions(token),
          "protocolVersion" => params["protocolVersion"],
          "serverInfo" => %{"name" => "emisar", "version" => "0.1.0"}
        }
      },
      id
    )
  end

  def answer(%{"method" => method, "id" => id}, "audit-" <> _token)
      when method in ["tools/list", "tools/call"] do
    respond(
      200,
      %{
        "error" => %{
          "code" => -32_002,
          "data" => %{"required" => "mcp"},
          "message" => "wrong key kind"
        }
      },
      id
    )
  end

  def answer(%{"method" => "tools/list", "id" => id}, _token),
    do: respond(200, %{"result" => json(@tools_list)}, id)

  def answer(
        %{"method" => "tools/call", "id" => id, "params" => %{"name" => name} = params},
        token
      ),
      do: respond(200, %{"result" => tool_answer(name, params["arguments"], token)}, id)

  # Emisar's ActionTools answer for a key its policy lets read but not dispatch.
  defp tool_answer("run_action", _arguments, "viewer-" <> _token) do
    fixed_result(
      %{
        "dispatch_started" => false,
        "error" => %{
          "code" => "not_allowed",
          "message" => "This key cannot dispatch actions.",
          "retryable" => false
        },
        "ok" => false
      },
      true
    )
  end

  # A run held for review, as Emisar answers it when the call is made: the
  # approval request expires a day later, like the published example's.
  defp tool_answer("run_action", _arguments, _token) do
    now = DateTime.utc_now()
    expires_at = DateTime.to_iso8601(DateTime.add(now, 86_400, :second))

    answer = json(@run_action_pending)

    runs =
      Enum.map(answer["runs"], fn run ->
        run
        |> Map.put("created_at", DateTime.to_iso8601(now))
        |> Map.put("wait_until", expires_at)
        |> put_in(["approval", "expires_at"], expires_at)
      end)

    fixed_result(%{answer | "runs" => runs}, false)
  end

  defp tool_answer("find_actions", _arguments, _token),
    do: fixed_result(json(@find_actions), false)

  defp tool_answer("wait_for_run", _arguments, _token),
    do: fixed_result(json(@wait_for_run), false)

  # The portal's answer to a name that is not one of its fixed tools.
  defp tool_answer(_name, _arguments, _token) do
    fixed_result(
      %{
        "dispatch_started" => false,
        "error" => %{
          "code" => "unknown_tool",
          "message" =>
            "Unknown tool. Emisar exposes only its 14 fixed API tools; an action id like 'postgres.restart' is not a tool. Discover with find_actions/get_action, then dispatch via run_action.",
          "retryable" => false
        },
        "ok" => false
      },
      true
    )
  end

  # ResponseBudget.fixed_result/2 in the portal.
  defp fixed_result(payload, is_error) do
    %{
      "content" => [%{"text" => Jason.encode!(payload), "type" => "text"}],
      "isError" => is_error,
      "structuredContent" => payload
    }
  end

  defp json(path), do: path |> File.read!() |> Jason.decode!()

  defp instructions("leaky-" <> _rest = token), do: File.read!(@instructions) <> " Key: " <> token
  defp instructions(_token), do: File.read!(@instructions)

  defp respond(status, body, id),
    do:
      {:ok,
       %{body: Map.merge(%{"id" => id, "jsonrpc" => "2.0"}, body), headers: [], status: status}}
end
