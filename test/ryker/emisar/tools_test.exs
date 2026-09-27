defmodule Ryker.Emisar.ToolsTest do
  # Emisar is `Ryker.TestSupport.EmisarMCP` here (config/test.exs): it answers
  # as emisar.dev did on 2026-09-27 and tells this process what it was sent.
  use Ryker.DataCase, async: true

  alias Ryker.Credentials
  alias Ryker.Emisar.Tools

  @actor "control-plane:local"
  @tools_list "testdata/emisar/tools_list.json" |> File.read!() |> Jason.decode!()
  @instructions File.read!("testdata/emisar/instructions.txt")

  # 2026-09-27: asked by voice whether it saw Emisar's tools, Ryker said only
  # the approval receipt was there. A Work session in an environment with
  # Emisar had never been given one Emisar tool: they were expected from an MCP
  # server on the worker, which the bundled worker never had.
  test "an environment's catalog is Emisar's own tools and instructions, read with its key" do
    key = key!("emk-")
    pin = pin!(key)

    assert {:ok, catalog} = Tools.catalog(pin)
    assert catalog.tools == @tools_list["tools"]
    assert catalog.instructions == @instructions

    assert_received {:emisar_mcp, %{body: %{"method" => "initialize"}, token: ^key}}
    assert_received {:emisar_mcp, %{body: %{"method" => "tools/list"}, token: ^key}}
  end

  test "a catalog is read once per key, and read again with a new key" do
    pin = pin!(key!("emk-"))
    assert {:ok, _catalog} = Tools.catalog(pin)
    assert_received {:emisar_mcp, %{body: %{"method" => "initialize"}}}
    assert_received {:emisar_mcp, %{body: %{"method" => "tools/list"}}}

    assert {:ok, _catalog} = Tools.catalog(pin)
    refute_received {:emisar_mcp, _request}

    replacement = key!("emk-")
    assert {:ok, _metadata} = Credentials.put(:emisar, "production", replacement, @actor)

    assert {:ok, _catalog} = Tools.catalog(pin)
    assert_received {:emisar_mcp, %{body: %{"method" => "tools/list"}, token: ^replacement}}
  end

  test "a refused key, a key of another kind, a missing key and an unreachable Emisar list nothing" do
    assert Tools.catalog(pin!(key!("refused-"))) == {:error, :key_refused}
    assert Tools.catalog(pin!(key!("audit-"))) == {:error, :key_refused}

    unreachable = pin!(key!("emk-"), "https://unreachable.example/api/mcp/rpc")
    assert Tools.catalog(unreachable) == {:error, :unavailable}

    assert Tools.catalog(%{pin!(key!("emk-")) | connection_ref: "deleted"}) ==
             {:error, :not_configured}
  end

  test "a call reaches Emisar with the environment's key and returns Emisar's answer unchanged" do
    key = key!("emk-")
    pin = pin!(key)
    {:ok, catalog} = Tools.catalog(pin)
    arguments = %{"limit" => 2, "query" => "disk usage"}

    assert {:ok, answer} = Tools.call(pin, tool(catalog, "find_actions"), arguments)

    assert answer == %{
             "content" => [
               %{"text" => Jason.encode!(find_actions()), "type" => "text"}
             ],
             "isError" => false,
             "structuredContent" => find_actions()
           }

    assert_received {:emisar_mcp,
                     %{
                       body: %{
                         "jsonrpc" => "2.0",
                         "method" => "tools/call",
                         "params" => %{"arguments" => ^arguments, "name" => "find_actions"}
                       },
                       headers: headers,
                       path: "/api/mcp/rpc",
                       token: ^key
                     }}

    # A read changes nothing, so it carries no operation to recover.
    refute List.keymember?(headers, "emisar-operation-id", 0)
    assert {"mcp-protocol-version", "2025-11-25"} in headers
  end

  test "Emisar's refusal of an action is Emisar's answer, passed through as it came" do
    pin = pin!(key!("viewer-"))
    {:ok, catalog} = Tools.catalog(pin)

    assert {:ok, %{"isError" => true, "structuredContent" => refusal}} =
             Tools.call(pin, tool(catalog, "run_action"), run_arguments())

    assert refusal["error"]["code"] == "not_allowed"
  end

  test "a refused key and an unreachable Emisar are plain failures of the call" do
    {:ok, catalog} = Tools.catalog(pin!(key!("emk-")))

    assert Tools.call(pin!(key!("refused-")), tool(catalog, "find_actions"), %{}) ==
             {:error, :key_refused}

    unreachable = pin!(key!("emk-"), "https://unreachable.example/api/mcp/rpc")

    assert Tools.call(unreachable, tool(catalog, "run_action"), run_arguments()) ==
             {:error, :unavailable}
  end

  # Emisar: "If transport fails after a mutation may have reached Emisar,
  # recover through its operation ID; never repeat the mutation merely because
  # the response was lost." Ryker names the operation before it sends one, so a
  # lost answer still says which operation to look up.
  test "a mutation whose answer is lost is reported with its operation id and never sent again" do
    pin = pin!(key!("emk-"), "https://silent.example/api/mcp/rpc")
    assert {:ok, catalog} = Tools.catalog(pin)

    assert {:error, {:no_answer, operation_id}} =
             Tools.call(pin, tool(catalog, "run_action"), run_arguments())

    assert operation_id =~ ~r/\Aop_[0-7][0-9A-HJKMNP-TV-Z]{25}\z/

    assert_received {:emisar_mcp, %{body: %{"method" => "tools/call"}, headers: headers}}
    assert {"emisar-operation-id", operation_id} in headers
    refute_received {:emisar_mcp, %{body: %{"method" => "tools/call"}}}

    # A read that gets no answer changed nothing and has nothing to recover.
    assert Tools.call(pin, tool(catalog, "find_actions"), %{"query" => "disk"}) ==
             {:error, :unavailable}
  end

  test "each mutation is its own operation" do
    pin = pin!(key!("emk-"))
    {:ok, catalog} = Tools.catalog(pin)

    for _attempt <- 1..2,
        do: assert({:ok, _answer} = Tools.call(pin, tool(catalog, "run_action"), run_arguments()))

    assert_received {:emisar_mcp, %{body: %{"method" => "tools/call"}, headers: first}}
    assert_received {:emisar_mcp, %{body: %{"method" => "tools/call"}, headers: second}}

    refute List.keyfind(first, "emisar-operation-id", 0) ==
             List.keyfind(second, "emisar-operation-id", 0)
  end

  test "an answer that carries the environment's key is withheld" do
    # This key is also a phrase in Emisar's find_actions answer, the plainest
    # way to have an answer carry it. Nothing Emisar says should, but whatever
    # reaches the model must not.
    pin = pin!("Filesystem disk usage")
    {:ok, catalog} = Tools.catalog(pin)

    assert Tools.call(pin, tool(catalog, "find_actions"), %{"query" => "disk"}) ==
             {:error, :answer_withheld}
  end

  defp tool(catalog, name), do: Enum.find(catalog.tools, &(&1["name"] == name))

  defp find_actions, do: "testdata/emisar/find_actions.json" |> File.read!() |> Jason.decode!()

  defp run_arguments do
    %{
      "action_id" => "linux.disk_usage",
      "args" => %{"paths" => ["/srv"]},
      "pack_ref" =>
        "linux-core@0.5.0/sha256:f4f5f29abc2aa8ccef433224da60d01159ba1434d6749172ef3795583d794bcf",
      "reason" => "Check whether /srv filled before the reload storm.",
      "runner_refs" => ["nomad-hvn01~f5e3a96782c44bd31186fcaa14ba6efb"]
    }
  end

  # A key of its own for each test: the catalog cache outlives the sandbox.
  defp key!(prefix),
    do: prefix <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)

  defp pin!(key, rpc_url \\ "https://emisar.dev/api/mcp/rpc") do
    assert {:ok, _metadata} = Credentials.put(:emisar, "production", key, @actor)
    %{connection_ref: "production", account_ref: "key-production", rpc_url: rpc_url}
  end
end
