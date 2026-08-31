defmodule Responder.Delivery.BinaryClientTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Responder.Delivery.BinaryClient

  defmodule FilePlug do
    @behaviour Plug

    @impl true
    def init(options), do: options

    @impl true
    def call(conn, test_pid) do
      send(test_pid, {:binary_request, get_req_header(conn, "authorization")})

      body =
        if conn.request_path == "/too-large",
          do: String.duplicate("x", 65),
          else: "exact file bytes"

      conn
      |> put_resp_header("content-type", "application/octet-stream")
      |> send_resp(200, body)
    end
  end

  test "streams authenticated bytes under the caller's exact limit" do
    port = unused_port!()

    child =
      Bandit.child_spec(
        ip: {127, 0, 0, 1},
        plug: {FilePlug, self()},
        port: port,
        startup_log: false
      )
      |> Map.put(:id, :delivery_binary_client_test_server)

    start_supervised!(child)

    assert {:ok, client} =
             BinaryClient.new(%{
               finch: Responder.CoopFinch,
               receive_timeout: 2_000,
               token_provider: fn -> {:ok, "trusted-token"} end
             })

    assert {:ok, %{body: "exact file bytes", status: 200}} =
             BinaryClient.get(client, "http://127.0.0.1:#{port}/file", 64)

    assert_receive {:binary_request, ["Bearer trusted-token"]}

    assert BinaryClient.get(client, "http://127.0.0.1:#{port}/too-large", 64) ==
             {:error, {:delivery_protocol_error, :response_too_large}}
  end

  test "rejects malformed configuration, credentials, and request bounds" do
    valid = %{
      finch: Responder.CoopFinch,
      receive_timeout: 2_000,
      token_provider: fn -> {:ok, "trusted-token"} end
    }

    assert {:ok, client} = BinaryClient.new(valid)

    for attributes <- [
          %{valid | finch: "bad"},
          %{valid | receive_timeout: 10},
          %{valid | token_provider: :bad}
        ] do
      assert {:error, {:invalid_delivery_binary_client, _field}} =
               BinaryClient.new(attributes)
    end

    assert BinaryClient.new(%{}) == {:error, {:invalid_delivery_binary_client, :fields}}
    assert BinaryClient.new(:invalid) == {:error, {:invalid_delivery_binary_client, :fields}}
    assert {:ok, _keyword_client} = BinaryClient.new(Map.to_list(valid))

    assert BinaryClient.get(%{}, "https://files.slack.com/file", 64) ==
             {:error, {:invalid_delivery_binary_request, :client}}

    assert BinaryClient.get(client, <<255>>, 64) ==
             {:error, {:invalid_delivery_binary_request, :url}}

    assert BinaryClient.get(client, "https://files.slack.com/file", 0) ==
             {:error, {:invalid_delivery_binary_request, :maximum_bytes}}

    assert {:ok, unavailable} =
             BinaryClient.new(%{valid | token_provider: fn -> {:error, :vault_down} end})

    assert BinaryClient.get(unavailable, "https://files.slack.com/file", 64) ==
             {:error, {:delivery_credentials_unavailable, :vault_down}}

    for token_provider <- [fn -> :unexpected end, fn -> raise "vault crashed" end] do
      assert {:ok, invalid_token} = BinaryClient.new(%{valid | token_provider: token_provider})

      assert {:error, {:delivery_credentials_unavailable, _reason}} =
               BinaryClient.get(invalid_token, "https://files.slack.com/file", 64)
    end
  end

  defp unused_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
