defmodule Responder.Delivery.JSONClientTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Responder.Delivery.JSONClient

  defmodule EchoPlug do
    @behaviour Plug

    @impl true
    def init(options), do: options

    @impl true
    def call(conn, test_pid) do
      case conn.request_path do
        "/empty" ->
          send_resp(conn, 204, "")

        "/invalid" ->
          send_resp(conn, 502, "not-json")

        "/too-large" ->
          send_resp(conn, 200, String.duplicate("x", 2 * 1_024 * 1_024 + 1))

        "/too-large-stream" ->
          conn = send_chunked(conn, 200)
          {:ok, conn} = chunk(conn, String.duplicate("x", 2 * 1_024 * 1_024 + 1))
          send(test_pid, {:oversized_chunk_sent, self()})

          receive do
            :finish_oversized_response -> conn
          end

        _other ->
          {:ok, body, conn} = read_body(conn)

          send(test_pid, {
            :request,
            conn.method,
            conn.request_path,
            get_req_header(conn, "authorization"),
            get_req_header(conn, "x-test-header"),
            body
          })

          conn
          |> put_resp_content_type("application/json")
          |> put_resp_header("x-response", "bounded")
          |> send_resp(201, Jason.encode!(%{"received" => Jason.decode!(body)}))
      end
    end
  end

  test "sends bounded authenticated JSON without exposing token choice to the request" do
    port = unused_port!()

    child =
      Bandit.child_spec(
        ip: {127, 0, 0, 1},
        plug: {EchoPlug, self()},
        port: port,
        startup_log: false
      )
      |> Map.put(:id, :delivery_json_client_test_server)

    start_supervised!(child)

    assert {:ok, client} =
             JSONClient.new(%{
               base_url: "http://127.0.0.1:#{port}",
               finch: Responder.CoopFinch,
               receive_timeout: 2_000,
               token_provider: fn -> {:ok, "trusted-token"} end
             })

    assert {:ok, response} =
             JSONClient.request(
               client,
               :post,
               "/v1/example",
               %{"arbitrary" => [1, true]},
               [{"x-test-header", "yes"}]
             )

    assert response.status == 201
    assert response.body == %{"received" => %{"arbitrary" => [1, true]}}
    assert {"x-response", "bounded"} in response.headers

    assert_receive {
      :request,
      "POST",
      "/v1/example",
      ["Bearer trusted-token"],
      ["yes"],
      ~s({"arbitrary":[1,true]})
    }

    assert {:ok, %{status: 201}} =
             JSONClient.request(client, :patch, "/v1/example", %{"updated" => true}, [])

    assert_receive {
      :request,
      "PATCH",
      "/v1/example",
      ["Bearer trusted-token"],
      [],
      ~s({"updated":true})
    }
  end

  test "rejects unsafe endpoints, malformed paths, and unavailable credentials" do
    valid = %{
      base_url: "https://api.example.test",
      finch: Responder.CoopFinch,
      receive_timeout: 2_000,
      token_provider: fn -> {:ok, "trusted-token"} end
    }

    invalid = [
      %{valid | base_url: "http://api.example.test"},
      %{valid | base_url: "https://user@example.test"},
      %{valid | finch: "not-an-atom"},
      %{valid | receive_timeout: 10},
      %{valid | token_provider: :not_a_function}
    ]

    Enum.each(invalid, fn attributes ->
      assert {:error, {:invalid_delivery_json_client, _field}} = JSONClient.new(attributes)
    end)

    assert {:ok, client} = JSONClient.new(valid)

    assert {:error, {:invalid_delivery_json_request, :path}} =
             JSONClient.request(client, :get, "https://attacker.test", nil, [])

    assert {:error, {:invalid_delivery_json_request, :method}} =
             JSONClient.request(client, :delete, "/v1/example", nil, [])

    assert {:ok, unavailable} =
             JSONClient.new(%{valid | token_provider: fn -> {:error, :vault_unavailable} end})

    assert JSONClient.request(unavailable, :get, "/v1/example", nil, []) ==
             {:error, {:delivery_credentials_unavailable, :vault_unavailable}}
  end

  test "bounds request and response documents and validates every trusted field" do
    port = unused_port!()

    child =
      Bandit.child_spec(
        ip: {127, 0, 0, 1},
        plug: {EchoPlug, self()},
        port: port,
        startup_log: false
      )
      |> Map.put(:id, :delivery_json_client_bounds_server)

    start_supervised!(child)

    attributes = %{
      base_url: "http://localhost:#{port}/",
      finch: Responder.CoopFinch,
      receive_timeout: 2_000,
      token_provider: fn -> {:ok, "trusted-token"} end
    }

    assert {:ok, client} = JSONClient.new(attributes)
    assert client.base_url == "http://localhost:#{port}"

    assert {:ok, %{body: nil, status: 204}} =
             JSONClient.request(client, :get, "/empty", nil, [])

    assert {:ok, %{body: "not-json", headers: headers, status: 502}} =
             JSONClient.request(client, :get, "/invalid", nil, [])

    assert {"content-length", "8"} in headers

    assert JSONClient.request(client, :get, "/too-large", nil, []) ==
             {:error, {:delivery_protocol_error, :response_too_large}}

    assert JSONClient.request(client, :post, "/v1/example", self(), []) ==
             {:error, {:invalid_delivery_json_request, :document}}

    assert JSONClient.request(client, :get, "//attacker.test/path", nil, []) ==
             {:error, {:invalid_delivery_json_request, :path}}

    assert JSONClient.request(client, :get, "/v1/example", nil, [{"Authorization", "bad"}]) ==
             {:error, {:invalid_delivery_json_request, :headers}}

    assert JSONClient.request(client, :get, "/v1/example", nil, :invalid) ==
             {:error, {:invalid_delivery_json_request, :headers}}

    assert JSONClient.request(%{}, :get, "/v1/example", nil, []) ==
             {:error, {:invalid_delivery_json_request, :client}}
  end

  test "stops reading an oversized response before the provider finishes it" do
    port = unused_port!()

    child =
      Bandit.child_spec(
        ip: {127, 0, 0, 1},
        plug: {EchoPlug, self()},
        port: port,
        startup_log: false
      )
      |> Map.put(:id, :delivery_json_client_stream_bound_server)

    start_supervised!(child)

    assert {:ok, client} =
             JSONClient.new(%{
               base_url: "http://127.0.0.1:#{port}",
               finch: Responder.CoopFinch,
               receive_timeout: 2_000,
               token_provider: fn -> {:ok, "trusted-token"} end
             })

    task = Task.async(fn -> JSONClient.request(client, :get, "/too-large-stream", nil, []) end)
    assert_receive {:oversized_chunk_sent, server}, 2_000

    try do
      assert Task.yield(task, 500) ==
               {:ok, {:error, {:delivery_protocol_error, :response_too_large}}}
    after
      send(server, :finish_oversized_response)
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "rejects malformed configuration and invalid token provider results" do
    valid = [
      base_url: "https://api.example.test",
      finch: Responder.CoopFinch,
      receive_timeout: 2_000,
      token_provider: fn -> {:ok, "trusted-token"} end
    ]

    assert {:ok, _client} = JSONClient.new(valid)

    assert JSONClient.new(valid ++ [finch: Responder.CoopFinch]) ==
             {:error, {:invalid_delivery_json_client, :fields}}

    assert JSONClient.new(%{base_url: "https://api.example.test"}) ==
             {:error, {:invalid_delivery_json_client, :fields}}

    assert JSONClient.new(:invalid) == {:error, {:invalid_delivery_json_client, :fields}}

    Enum.each(
      [
        fn -> {:ok, ""} end,
        fn -> :unexpected end,
        fn -> raise "vault crashed" end
      ],
      fn token_provider ->
        assert {:ok, client} = JSONClient.new(Keyword.put(valid, :token_provider, token_provider))

        assert {:error, {:delivery_credentials_unavailable, _reason}} =
                 JSONClient.request(client, :get, "/v1/example", nil, [])
      end
    )
  end

  defp unused_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
