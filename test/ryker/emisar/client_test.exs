defmodule Ryker.Emisar.ClientTest do
  use ExUnit.Case, async: true

  alias Ryker.Emisar.{Client, RunState}

  defmodule Requester do
    def request({test_pid, response}, method, path, document, headers) do
      send(test_pid, {:request, method, path, document, headers})
      response
    end
  end

  # Emisar's own published example, byte for byte. It is the contract between the
  # two repositories: a shape either side changes alone fails here rather than in
  # a governed-review card nobody can repaint.
  test "reads Emisar's published review receipt off the wire" do
    run =
      "test/ryker/emisar/fixtures/wait_for_run_review_v1.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("run")

    assert {:ok, client} = client_for(run)

    assert {:ok, %RunState{review: review}} = Client.wait_for_run(client, run["run_id"])

    assert review == run["review"]
    assert review["approved_count"] == 1
    assert review["override"]["waived_approvals"] == 1
    assert review["command"]["kind"] == "executed"
  end

  test "a review shape this host cannot validate is a protocol error, not a card" do
    run =
      "test/ryker/emisar/fixtures/wait_for_run_review_v1.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("run")

    # An override with no reason, a vote with no decision, and a receipt whose
    # tally exceeds its own requirement each fail the read closed: the monitor
    # defers and the card keeps the last receipt it could prove.
    invalid = [
      put_in(run, ["review", "override", "reason"], "   "),
      put_in(run, ["review", "decisions"], [%{"actor" => "Jane Doe"}]),
      put_in(run, ["review", "approved_count"], 9),
      put_in(run, ["review", "invented"], true)
    ]

    for candidate <- invalid do
      assert {:ok, client} = client_for(candidate)

      assert Client.wait_for_run(client, candidate["run_id"]) ==
               {:error, {:emisar_protocol_error, :review}}
    end
  end

  defp client_for(run) do
    response =
      {:ok,
       %{
         body: %{
           "id" => "response-1",
           "jsonrpc" => "2.0",
           "result" => %{
             "isError" => false,
             "structuredContent" => %{"ok" => true, "run" => run}
           }
         },
         headers: [],
         status: 200
       }}

    Client.new(%{
      http: {self(), response},
      requester: Requester,
      rpc_origin: "https://emisar.dev",
      rpc_path: "/api/mcp/rpc"
    })
  end

  test "reads one exact run through the bounded read-only MCP operation" do
    response =
      {:ok,
       %{
         body: %{
           "id" => "response-1",
           "jsonrpc" => "2.0",
           "result" => %{
             "isError" => false,
             "structuredContent" => %{
               "ok" => true,
               "run" => %{
                 "action_id" => "nomad.alloc_restart",
                 "error_message" => "",
                 "operation_id" => "op-1",
                 "pack_ref" => "nomad@1#sha256:abc",
                 "run_id" => "run-1",
                 "run_url" => "https://emisar.example/app/acme/runs/run-1",
                 "runner_ref" => "production-runner",
                 "status" => "running"
               }
             }
           }
         },
         headers: [],
         status: 200
       }}

    assert {:ok, client} =
             Client.new(%{
               http: {self(), response},
               requester: Requester,
               rpc_origin: "https://emisar.example",
               rpc_path: "/api/mcp/rpc"
             })

    assert {:ok, %RunState{run_id: "run-1", status: "running", error_message: nil}} =
             Client.wait_for_run(client, "run-1")

    assert_receive {:request, :post, "/api/mcp/rpc", document, headers}
    assert document["method"] == "tools/call"

    assert document["params"] == %{
             "arguments" => %{"run_id" => "run-1", "timeout" => "0"},
             "name" => "wait_for_run"
           }

    assert {"mcp-protocol-version", "2025-11-25"} in headers
  end

  test "rejects foreign URLs, malformed identities, errors, and unsafe client configuration" do
    valid = valid_client_attributes(nil)

    assert {:error, {:invalid_emisar_client, :rpc_origin}} =
             Client.new(%{valid | rpc_origin: "http://emisar.example"})

    assert {:error, {:invalid_emisar_client, :rpc_path}} =
             Client.new(%{valid | rpc_path: "https://evil.example/rpc"})

    assert {:ok, client} =
             Client.new(%{
               valid
               | http:
                   {self(),
                    response(%{
                      "action_id" => "nomad.alloc_restart",
                      "error_message" => nil,
                      "operation_id" => "op-1",
                      "pack_ref" => "nomad@1#sha256:abc",
                      "run_id" => "run-1",
                      "run_url" => "https://evil.example/app/acme/runs/run-1",
                      "runner_ref" => "production-runner",
                      "status" => "success"
                    })}
             })

    assert Client.wait_for_run(client, "run-1") ==
             {:error, {:emisar_protocol_error, :run_url}}

    assert {:ok, invalid_status} =
             Client.new(%{
               valid
               | http:
                   {self(),
                    response(%{
                      "action_id" => "nomad.alloc_restart",
                      "error_message" => nil,
                      "operation_id" => "op-1",
                      "pack_ref" => "nomad@1#sha256:abc",
                      "run_id" => "run-1",
                      "run_url" => nil,
                      "runner_ref" => "production-runner",
                      "status" => "invented"
                    })}
             })

    assert Client.wait_for_run(invalid_status, "run-1") ==
             {:error, {:emisar_protocol_error, :status}}

    assert {:ok, http_error} =
             Client.new(%{valid | http: {self(), {:ok, %{body: %{}, status: 503}}}})

    assert {:error, {:emisar_http_error, 503, _detail}} =
             Client.wait_for_run(http_error, "run-1")
  end

  test "contains every malformed MCP envelope and unsafe optional field" do
    assert Client.new(%{valid_client_attributes(nil) | requester: String}) ==
             {:error, {:invalid_emisar_client, :requester}}

    assert Client.new(%{valid_client_attributes(nil) | rpc_origin: nil}) ==
             {:error, {:invalid_emisar_client, :rpc_origin}}

    assert Client.new(http: :one, http: :two) ==
             {:error, {:invalid_emisar_client, :fields}}

    assert Client.new(:invalid) == {:error, {:invalid_emisar_client, :fields}}
    assert Client.wait_for_run(:invalid, "run-1") == {:error, {:invalid_emisar_client, :client}}

    rpc_error = %{
      body: %{
        "error" => %{"code" => -32_001, "message" => String.duplicate("x", 1_100)},
        "jsonrpc" => "2.0"
      },
      status: 200
    }

    assert {:error, {:emisar_rpc_error, -32_001, message}} =
             wait_response({:ok, rpc_error})

    assert byte_size(message) == 1_000

    assert wait_response({:ok, %{body: %{"unexpected" => true}, status: 200}}) ==
             {:error, {:emisar_protocol_error, :response}}

    tool_error =
      structured_response(%{
        "error" => %{"code" => "denied", "message" => String.duplicate("d", 1_100)},
        "ok" => false
      })

    assert {:error, {:emisar_tool_error, "denied", detail}} = wait_response(tool_error)
    assert byte_size(detail) == 1_000

    assert wait_response(structured_response(%{"ok" => true})) ==
             {:error, {:emisar_protocol_error, :run}}

    assert wait_response(response(run_document(%{"run_url" => 42}))) ==
             {:error, {:emisar_protocol_error, :run_url}}

    assert wait_response(response(run_document(%{"error_message" => <<0>>}))) ==
             {:error, {:emisar_protocol_error, :error_message}}

    assert {:ok,
            %RunState{
              error_message: "provider reported one bounded warning",
              run_url: "https://emisar.example/app/acme/runs/run-1"
            }} =
             wait_response(
               response(
                 run_document(%{
                   "error_message" => "provider reported one bounded warning",
                   "run_url" => "https://emisar.example:443/app/acme/runs/run-1"
                 })
               )
             )
  end

  test "keyword clients normalize empty optional values and default HTTPS ports" do
    attributes = valid_client_attributes(response(run_document(%{"run_url" => ""})))

    assert {:ok, client} = Client.new(Map.to_list(attributes))

    assert {:ok, %RunState{error_message: nil, run_url: nil}} =
             Client.wait_for_run(client, "run-1")

    origin_with_port = %{attributes | rpc_origin: "https://emisar.example:443"}
    response = response(run_document(%{"run_url" => "https://emisar.example/runs/run-1"}))
    assert {:ok, client} = Client.new(%{origin_with_port | http: {self(), response}})

    assert {:ok, %RunState{run_url: "https://emisar.example/runs/run-1"}} =
             Client.wait_for_run(client, "run-1")
  end

  defp response(run) do
    {:ok,
     %{
       body: %{
         "id" => "response-1",
         "jsonrpc" => "2.0",
         "result" => %{
           "isError" => false,
           "structuredContent" => %{"ok" => true, "run" => run}
         }
       },
       status: 200
     }}
  end

  defp structured_response(structured) do
    {:ok,
     %{
       body: %{
         "id" => "response-1",
         "jsonrpc" => "2.0",
         "result" => %{"isError" => false, "structuredContent" => structured}
       },
       status: 200
     }}
  end

  defp run_document(overrides) do
    Map.merge(
      %{
        "action_id" => "nomad.alloc_restart",
        "error_message" => nil,
        "operation_id" => "op-1",
        "pack_ref" => "nomad@1#sha256:abc",
        "run_id" => "run-1",
        "run_url" => nil,
        "runner_ref" => "production-runner",
        "status" => "failed"
      },
      overrides
    )
  end

  defp wait_response(response) do
    {:ok, client} = Client.new(valid_client_attributes(response))
    Client.wait_for_run(client, "run-1")
  end

  defp valid_client_attributes(response) do
    %{
      http: {self(), response},
      requester: Requester,
      rpc_origin: "https://emisar.example",
      rpc_path: "/api/mcp/rpc"
    }
  end
end
