defmodule Ryker.TestSupport.EmisarMCP do
  @moduledoc """
  Emisar's MCP endpoint as it answers, harvested from emisar.dev on 2026-09-27
  and matching `dispatch/3` in the portal's mcp_rpc_controller.ex:
  `initialize` names the server and never the account behind a key,
  `tools/list` lists the agent tools for an agent key, a refused key gets HTTP
  401 with JSON-RPC error -32001, and a key of another kind gets -32002.

  Ryker's own double once answered `initialize` with an account Emisar never
  sends, so every real Emisar key was refused with "Emisar did not say which
  account this token belongs to" while its tests passed.

  A token starting "refused-" is refused; one starting "audit-" is an
  audit-export key, which cannot run agent tools.
  """

  @spec answer(map(), String.t()) :: {:ok, map()}
  def answer(%{"id" => id}, "refused-" <> _token),
    do: respond(401, %{"error" => %{"code" => -32_001, "message" => "unauthorized"}}, id)

  def answer(%{"method" => "initialize", "id" => id, "params" => params}, _token) do
    respond(
      200,
      %{
        "result" => %{
          "capabilities" => %{"tools" => %{"listChanged" => false}},
          "instructions" => "Emisar runs approved actions on your infrastructure.",
          "protocolVersion" => params["protocolVersion"],
          "serverInfo" => %{"name" => "emisar", "version" => "0.1.0"}
        }
      },
      id
    )
  end

  def answer(%{"method" => "tools/list", "id" => id}, "audit-" <> _token) do
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

  def answer(%{"method" => "tools/list", "id" => id}, _token) do
    tools = Enum.map(~w(find_actions get_action run_action wait_for_run), &%{"name" => &1})
    respond(200, %{"result" => %{"tools" => tools}}, id)
  end

  defp respond(status, body, id),
    do:
      {:ok,
       %{body: Map.merge(%{"id" => id, "jsonrpc" => "2.0"}, body), headers: [], status: status}}
end
