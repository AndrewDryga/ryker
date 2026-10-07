defmodule Ryker.StateTools.EmisarToolsTest do
  # Emisar is `Ryker.TestSupport.EmisarMCP` here (config/test.exs): it answers
  # as emisar.dev did on 2026-09-27 and tells this process what it was sent.
  use Ryker.DataCase, async: false
  import Plug.Conn
  import Plug.Test
  alias Ryker.{Credentials, Episodes, Repo, Settings}
  alias Ryker.Emisar.Approval
  alias Ryker.Episodes.Episode
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Inspectors
  alias Ryker.Records
  alias Ryker.Records.Record
  alias Ryker.StateTools.Router
  alias Ryker.Work.{Custody, SubmissionBuilder}

  @actor "control-plane:local"
  @cursor_secret "host-owned-memory-cursor-secret"
  @policy_digest String.duplicate("a", 64)
  @tools_list "testdata/emisar/tools_list.json" |> File.read!() |> Jason.decode!()
  @emisar_names Enum.map(@tools_list["tools"], & &1["name"])

  # 2026-09-27: asked by voice whether it saw any tools in Emisar, Ryker said
  # that during work only the approval receipt was exposed: runner listing,
  # pack listing and action execution were not available. Its briefing said
  # the environment had Emisar, and no Work session there had ever been given
  # one Emisar tool. They were expected from an MCP server on the worker, which
  # the bundled worker never had.
  test "a session in an environment with Emisar lists Emisar's tools, and a call reaches Emisar with that environment's key" do
    key = connect!("https://emisar.dev/api/mcp/rpc")
    options = bound_options(claim!("listed", "ops"))

    tools = list(options)
    names = Enum.map(tools, & &1["name"])

    # Exactly Emisar's own descriptors, under Emisar's names, after Ryker's own.
    assert Enum.filter(tools, &(&1["name"] in @emisar_names)) == @tools_list["tools"]
    assert Enum.take(names, -length(@emisar_names)) == @emisar_names
    assert "record_emisar_approval" in names
    assert "validate_final" in names

    arguments = %{"limit" => 2, "query" => "disk usage"}
    answer = call(options, "find_actions", arguments)

    # Emisar's answer, unchanged.
    assert answer["isError"] == false
    assert answer["structuredContent"] == find_actions()
    assert answer["content"] == [%{"text" => Jason.encode!(find_actions()), "type" => "text"}]

    assert_received {:emisar_mcp,
                     %{
                       body: %{
                         "method" => "tools/call",
                         "params" => %{"arguments" => ^arguments, "name" => "find_actions"}
                       },
                       token: ^key
                     }}
  end

  # An evaluation run only observes. It was offered the approval receipt it
  # could never record (2026-10-04 review).
  test "an evaluation run in an environment with Emisar is not offered the approval receipt" do
    connect!("https://emisar.dev/api/mcp/rpc")
    options = bound_options(claim!("shadow", "ops", execution_mode: :shadow))

    names = options |> list() |> Enum.map(& &1["name"])
    refute "record_emisar_approval" in names
  end

  test "a session in an environment without Emisar lists no Emisar tool and cannot call one" do
    connect!("https://emisar.dev/api/mcp/rpc")
    options = bound_options(claim!("plain", "plain"))

    names = options |> list() |> Enum.map(& &1["name"])
    assert Enum.filter(names, &(&1 in @emisar_names)) == []
    refute "record_emisar_approval" in names

    assert %{"isError" => true, "structuredContent" => %{"error" => "unknown_tool"}} =
             call(options, "find_actions", %{"query" => "disk"})

    refute_received {:emisar_mcp, _request}
  end

  test "a refused key or an unreachable Emisar lists none of its tools and is a plain tool error" do
    connect!("https://emisar.dev/api/mcp/rpc", "refused-")
    refused = bound_options(claim!("refused", "ops"))

    assert Enum.filter(list(refused), &(&1["name"] in @emisar_names)) == []

    assert %{
             "isError" => true,
             "structuredContent" => %{"error" => "emisar_key_refused: " <> why}
           } =
             call(refused, "find_actions", %{"query" => "disk"})

    assert why =~ "Nothing ran"

    connect!("https://unreachable.example/api/mcp/rpc")
    unreachable = bound_options(claim!("unreachable", "ops"))

    assert Enum.filter(list(unreachable), &(&1["name"] in @emisar_names)) == []

    assert %{"isError" => true, "structuredContent" => %{"error" => "emisar_unavailable: " <> _}} =
             call(unreachable, "run_action", run_arguments())
  end

  # Emisar: "If transport fails after a mutation may have reached Emisar,
  # recover through its operation ID; never repeat the mutation merely because
  # the response was lost."
  test "a mutation whose answer is lost says which operation to recover, and is not sent again" do
    connect!("https://silent.example/api/mcp/rpc")
    options = bound_options(claim!("silent", "ops"))

    assert %{"isError" => true, "structuredContent" => %{"error" => lost}} =
             call(options, "run_action", run_arguments())

    assert %{
             "code" => "emisar_no_answer",
             "message" => message,
             "next" => %{
               "arguments" => %{"operation_id" => operation_id},
               "tool" => "get_operation"
             },
             "operation_id" => operation_id
           } = lost

    assert message =~ "Do not repeat"
    assert_received {:emisar_mcp, %{body: %{"method" => "tools/call"}, headers: headers}}
    assert {"emisar-operation-id", operation_id} in headers
    refute_received {:emisar_mcp, %{body: %{"method" => "tools/call"}}}
  end

  test "an observe-only session sees only Emisar's read-only tools" do
    connect!("https://emisar.dev/api/mcp/rpc")
    options = bound_options(claim!("shadow", "ops", execution_mode: :shadow))

    names = options |> list() |> Enum.map(& &1["name"])
    assert Enum.filter(names, &(&1 in @emisar_names)) == ~w(find_actions get_action wait_for_run)

    assert %{"isError" => true, "structuredContent" => %{"error" => "unknown_tool"}} =
             call(options, "run_action", run_arguments())

    refute_received {:emisar_mcp, %{body: %{"method" => "tools/call"}}}
  end

  # Emisar holds a governed action for review and says so in its answer. The
  # receipt the model registers must be the one Emisar returned, field for
  # field, or Ryker has nothing it can watch and the work never resumes.
  test "a pending-approval result flows to record_emisar_approval, and Ryker watches that run" do
    connect!("https://emisar.dev/api/mcp/rpc")
    claim = claim!("approval", "ops")
    options = bound_options(claim)

    answer = call(options, "run_action", run_arguments())
    # Failed twice under the full suite's load on 2026-09-30 and never alone;
    # the answer says why the next time.
    assert answer["isError"] == false, "run_action answered #{inspect(answer)}"
    assert %{"runs" => [%{"status" => "pending_approval"} = run]} = answer["structuredContent"]

    receipt =
      run
      |> Map.take(~w(action_id operation_id pack_ref run_id runner_ref status))
      |> Map.merge(%{
        "approval_url" => run["approval"]["url"],
        "expires_at" => run["approval"]["expires_at"],
        "request_id" => run["approval"]["request_id"]
      })

    assert %{"isError" => false, "structuredContent" => %{"record_ref" => record_ref}} =
             call(options, "record_emisar_approval", receipt)

    assert %Record{kind: "emisar_approval", status: :open} =
             Repo.get_by!(Record, ref: record_ref)

    assert %Approval{status: :monitoring} =
             approval = Inspectors.emisar_approval("production", run["approval"]["request_id"])

    assert {approval.run_id, approval.operation_id, approval.runner_ref} ==
             {run["run_id"], run["operation_id"], run["runner_ref"]}
  end

  test "the key never appears in anything sent to the model" do
    key = connect!("https://emisar.dev/api/mcp/rpc")
    claim = claim!("secret", "ops")
    options = bound_options(claim)

    initialize = rpc("initialize", %{"protocolVersion" => "2025-11-25"}, options).resp_body
    listed = rpc("tools/list", %{}, options).resp_body

    called =
      for {name, arguments} <- [
            {"find_actions", %{"query" => "disk usage"}},
            {"run_action", run_arguments()},
            {"wait_for_run", %{"run_id" => "019f61cf-59b4-71d9-a78c-4ece74d1e164"}}
          ],
          do: rpc("tools/call", %{"arguments" => arguments, "name" => name}, options).resp_body

    assert {:ok, submission} = SubmissionBuilder.build(claim)

    for sent <- [initialize, listed, Jason.encode!(submission) | called],
        do: refute(sent =~ key)

    # The key did go to Emisar, once for each request.
    assert_received {:emisar_mcp, %{token: ^key}}

    # A key Emisar refuses is no more visible than one it accepts.
    refused = connect!("https://emisar.dev/api/mcp/rpc", "refused-")
    refused_options = bound_options(claim!("refused-secret", "ops"))

    for sent <- [
          rpc("tools/list", %{}, refused_options).resp_body,
          rpc(
            "tools/call",
            %{"arguments" => %{"query" => "disk"}, "name" => "find_actions"},
            refused_options
          ).resp_body
        ],
        do: refute(sent =~ refused)
  end

  defp list(options) do
    assert %{"result" => %{"tools" => tools}} =
             rpc("tools/list", %{}, options).resp_body |> Jason.decode!()

    tools
  end

  defp call(options, name, arguments) do
    response = rpc("tools/call", %{"arguments" => arguments, "name" => name}, options)
    assert response.status == 200
    assert %{"result" => result} = Jason.decode!(response.resp_body)
    result
  end

  defp rpc(method, params, options) do
    conn(
      :post,
      "/mcp",
      Jason.encode!(%{"id" => 1, "jsonrpc" => "2.0", "method" => method, "params" => params})
    )
    |> put_req_header("content-type", "application/json")
    |> Router.call(options)
  end

  defp find_actions, do: "testdata/emisar/find_actions.json" |> File.read!() |> Jason.decode!()

  defp run_arguments do
    %{
      "action_id" => "linux.disk_usage",
      "args" => %{"paths" => ["/srv"]},
      "pack_ref" =>
        "linux-core@0.5.0/sha256:f4f5f29abc2aa8ccef433224da60d01159ba1434d6749172ef3795583d794bcf",
      "reason" => "Check whether /srv filled before the reload storm.",
      "runner_refs" => ["nomad-hst01~f5e3a96782c44bd31186fcaa14ba6efb"]
    }
  end

  # The "ops" environment has Emisar at `rpc_url`; the "plain" one has none.
  # Each call stores a key of its own, because the catalog cache outlives the
  # test's sandbox.
  defp connect!(rpc_url, prefix \\ "emk-") do
    key = prefix <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
    {:ok, snapshot} = Settings.initialize(@actor)

    {:ok, snapshot} =
      Settings.put_emisar_connection(
        %{
          ref: "production",
          display_name: "Production",
          rpc_url: rpc_url,
          account_ref: "key-production",
          account_label: URI.parse(rpc_url).host,
          enabled_for_new_work: true,
          monitoring_enabled: true,
          verified_at: ~U[2026-09-27 12:00:00.000000Z]
        },
        snapshot.installation.revision,
        @actor
      )

    {:ok, snapshot} =
      Settings.put_environment(
        %{ref: "ops", display_name: "Ops", emisar_connection_ref: "production"},
        snapshot.installation.revision,
        @actor
      )

    {:ok, _snapshot} =
      Settings.put_environment(
        %{ref: "plain", display_name: "Plain"},
        snapshot.installation.revision,
        @actor
      )

    {:ok, _metadata} = Credentials.put(:emisar, "production", key, @actor)
    key
  end

  defp claim!(suffix, environment_ref, overrides \\ []) do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(
        Map.merge(
          %{
            episode_id: id,
            episode_key: "emisar-tools:#{suffix}:#{id}",
            native_input_id: "source:#{suffix}:#{id}",
            payload: %{"text" => "Is /srv filling up on nomad-hst01?"},
            turn_ref: "turn:#{suffix}:#{id}"
          },
          Map.new(overrides)
        )
      )

    assert {:ok, transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(
               id,
               "work-read-only",
               @policy_digest,
               nil,
               nil,
               nil,
               nil,
               environment_ref
             )

    Episode
    |> Repo.get!(transition.episode.id)
    |> Ecto.Changeset.change(updated_at: ~U[2000-01-01 00:00:00.000000Z])
    |> Repo.update!()

    assert {:ok, claim} = Custody.claim_next("worker:#{suffix}:#{id}", 60, :work)
    assert claim.episode.id == id
    claim
  end

  defp bound_options(claim) do
    Router.init(
      cursor_secret: Ryker.Secret.new(@cursor_secret),
      binding: %{
        episode: claim.episode,
        session: claim.session,
        state_token: Records.token(claim.turn),
        turn: claim.turn
      }
    )
  end
end
