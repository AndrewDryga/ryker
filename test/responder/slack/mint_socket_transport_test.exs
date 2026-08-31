defmodule Responder.Slack.MintSocketTransportTest do
  use ExUnit.Case, async: true

  alias Responder.Slack.MintSocketTransport

  defmodule Requester do
    def request(response, :post, "/apps.connections.open", %{}, []), do: response
  end

  defmodule FakeHTTP do
    def connect(:https, "wss-primary.slack.com", 443, options) do
      send(self(), {:connect_options, options})
      {:ok, {:http, self()}}
    end

    def close({_state, pid}) do
      send(pid, :connection_closed)
      :ok
    end
  end

  defmodule FakeWebSocket do
    def upgrade(:wss, {:http, pid}, "/link/?ticket=secret", []) do
      {:ok, {:upgrading, pid}, :request_ref}
    end

    def upgrade(:wss, {:http, pid} = conn, "/upgrade-fails", []) do
      send(pid, :upgrade_failed)
      {:error, conn, :rejected}
    end

    def stream({:upgrading, pid}, :handshake) do
      {:ok, {:upgrading, pid},
       [
         {:status, :request_ref, 101},
         {:headers, :request_ref, [{"upgrade", "websocket"}]},
         {:done, :request_ref}
       ]}
    end

    def stream({:upgrading, _pid}, :unknown_handshake), do: :unknown

    def stream({:upgrading, pid}, :handshake_transport_error) do
      {:error, {:upgrading, pid}, :closed, []}
    end

    def stream({:upgrading, pid}, :handshake_response_error) do
      {:ok, {:upgrading, pid}, [{:error, :request_ref, :refused}]}
    end

    def stream({:upgrading, pid}, :malformed_handshake) do
      {:ok, {:upgrading, pid}, [{:done, :request_ref}]}
    end

    def stream({:upgrading, _pid}, {:connect_options, _options}), do: :unknown
    def stream({:upgrading, _pid}, _message), do: :unknown

    def stream({:connected, pid}, {:wire, data}) do
      {:ok, {:connected, pid}, [{:data, :request_ref, data}]}
    end

    def stream({:connected, pid}, :transport_error) do
      {:error, {:connected, pid}, :closed, []}
    end

    def stream({:connected, _pid}, :unknown), do: :unknown

    def stream({:connected, pid}, :response_error) do
      {:ok, {:connected, pid}, [{:error, :request_ref, :closed}]}
    end

    def stream({:connected, pid}, :unexpected_response) do
      {:ok, {:connected, pid}, [{:done, :request_ref}]}
    end

    def new({:upgrading, pid}, :request_ref, 101, [{"upgrade", "websocket"}]) do
      {:ok, {:connected, pid}, {:websocket, pid}}
    end

    def decode({:websocket, pid}, data) do
      {:ok, {:websocket, pid}, [{:text, data}, {:ping, "probe"}]}
    end

    def decode({:decode_error, pid}, _data), do: {:error, {:decode_error, pid}, :invalid_frame}

    def encode({:websocket, pid}, frame) do
      {:ok, {:websocket, pid}, {:encoded, frame}}
    end

    def encode({:encode_error, pid}, _frame), do: {:error, {:encode_error, pid}, :closed}

    def stream_request_body({:connected, pid}, :request_ref, {:encoded, frame}) do
      send(pid, {:frame_sent, frame})
      {:ok, {:connected, pid}}
    end
  end

  test "accepts only a bounded secure Slack Socket Mode target" do
    assert MintSocketTransport.connection_target(
             "wss://wss-primary.slack.com/link/?ticket=secret&app_id=A1"
           ) ==
             {:ok,
              %{
                host: "wss-primary.slack.com",
                path: "/link/?ticket=secret&app_id=A1",
                port: 443
              }}

    assert {:error, {:invalid_slack_socket_url, :url}} =
             MintSocketTransport.connection_target("ws://wss-primary.slack.com/link")

    assert {:error, {:invalid_slack_socket_url, :url}} =
             MintSocketTransport.connection_target("wss://user@wss-primary.slack.com/link")

    assert MintSocketTransport.connection_target("wss://wss-primary.slack.com") ==
             {:ok, %{host: "wss-primary.slack.com", path: "/", port: 443}}

    assert MintSocketTransport.connection_target("wss://wss-primary.slack.com?ticket=secret") ==
             {:ok, %{host: "wss-primary.slack.com", path: "/?ticket=secret", port: 443}}

    assert MintSocketTransport.connection_target("wss://wss-primary.slack.com/link") ==
             {:ok, %{host: "wss-primary.slack.com", path: "/link", port: 443}}

    for url <- [
          "wss://attacker.example/link",
          "wss://wss-primary.slack.com.attacker.example/link",
          "wss://slack.com.evil.example/link",
          "wss://wss-primary.slack.com:444/link"
        ] do
      assert MintSocketTransport.connection_target(url) ==
               {:error, {:invalid_slack_socket_url, :url}}
    end

    assert MintSocketTransport.connection_target(nil) ==
             {:error, {:invalid_slack_socket_url, :url}}
  end

  test "fails closed when apps.connections.open does not return a usable URL" do
    options = %{
      http: {:ok, %{body: %{"error" => "invalid_auth", "ok" => false}, status: 200}},
      requester: Requester
    }

    assert MintSocketTransport.connect(options) ==
             {:error, {:slack_socket_open_failed, 200, "invalid_auth"}}
  end

  test "validates transport options and preserves open-call failures" do
    assert MintSocketTransport.connect(:invalid) ==
             {:error, {:invalid_slack_socket_transport, :fields}}

    assert MintSocketTransport.connect(http: :http, requester: Requester, requester: Requester) ==
             {:error, {:invalid_slack_socket_transport, :fields}}

    assert MintSocketTransport.connect(%{
             handshake_timeout_ms: 1,
             http: :http,
             requester: Requester
           }) == {:error, {:invalid_slack_socket_transport, :fields}}

    assert MintSocketTransport.connect(%{
             http: {:error, :app_token_unavailable},
             requester: Requester
           }) == {:error, :app_token_unavailable}

    assert MintSocketTransport.connect(%{
             http: {:ok, %{body: %{}, status: 503}},
             requester: Requester
           }) == {:error, {:slack_socket_open_failed, 503, :invalid_response}}

    assert MintSocketTransport.connect(%{
             http: {:ok, :invalid},
             requester: Requester
           }) == {:error, {:slack_socket_open_failed, :invalid_response}}
  end

  test "a valid open response proceeds to the secure socket connection" do
    response =
      {:ok,
       %{
         body: %{"ok" => true, "url" => "wss://127.0.0.1:1/socket"},
         status: 200
       }}

    assert {:error, _reason} =
             MintSocketTransport.connect(%{http: response, requester: Requester})
  end

  test "performs the secure upgrade and moves websocket frames without live Slack" do
    send(self(), :handshake)

    options = %{
      http:
        {:ok,
         %{
           body: %{
             "ok" => true,
             "url" => "wss://wss-primary.slack.com/link/?ticket=secret"
           },
           status: 200
         }},
      mint_http: FakeHTTP,
      mint_websocket: FakeWebSocket,
      requester: Requester
    }

    assert {:ok, state} = MintSocketTransport.connect(options)
    assert_received {:connect_options, connect_options}
    assert connect_options[:protocols] == [:http1]
    assert is_list(connect_options[:transport_opts][:cacerts])

    assert {:ok, streamed, [{:text, "hello"}, {:ping, "probe"}]} =
             MintSocketTransport.stream(state, {:wire, "hello"})

    assert {:ok, sent} = MintSocketTransport.send_frame(streamed, {:text, "ack"})
    assert_received {:frame_sent, {:text, "ack"}}

    assert :ok = MintSocketTransport.close(sent)
    assert_received {:frame_sent, :close}
    assert_received :connection_closed
  end

  test "fails closed on rejected and malformed websocket handshakes" do
    assert MintSocketTransport.connect(fake_options("/upgrade-fails")) ==
             {:error, {:slack_socket_upgrade_failed, :rejected}}

    assert_received :upgrade_failed
    assert_received :connection_closed

    send(self(), :handshake_response_error)

    assert MintSocketTransport.connect(fake_options()) ==
             {:error, {:slack_socket_upgrade_failed, :refused}}

    assert_received :connection_closed

    send(self(), :malformed_handshake)

    assert MintSocketTransport.connect(fake_options()) ==
             {:error, {:slack_socket_upgrade_failed, :response}}

    assert_received :connection_closed

    send(self(), :handshake_transport_error)

    assert MintSocketTransport.connect(fake_options()) ==
             {:error, {:slack_socket_upgrade_failed, :closed}}

    assert_received :connection_closed
  end

  test "ignores unrelated handshake messages and times out safely" do
    send(self(), :unknown_handshake)
    send(self(), :handshake)

    assert {:ok, state} = MintSocketTransport.connect(fake_options())
    assert :ok = MintSocketTransport.close(state)

    assert MintSocketTransport.connect(fake_options(%{handshake_timeout_ms: 100})) ==
             {:error, {:slack_socket_upgrade_failed, :timeout}}

    assert_received :connection_closed
  end

  test "surfaces runtime transport, decode, response, and encoding failures" do
    send(self(), :handshake)
    assert {:ok, state} = MintSocketTransport.connect(fake_options())

    assert MintSocketTransport.stream(state, :unknown) == {:unknown, state}

    assert {:error, {:slack_socket_transport, :closed, _conn}} =
             MintSocketTransport.stream(state, :transport_error)

    assert MintSocketTransport.stream(state, :response_error) ==
             {:error, {:slack_socket_transport, :closed}}

    assert MintSocketTransport.stream(state, :unexpected_response) ==
             {:error, {:slack_socket_transport, :response}}

    decode_error = %{state | websocket: {:decode_error, self()}}

    assert MintSocketTransport.stream(decode_error, {:wire, "bad"}) ==
             {:error, {:slack_socket_decode_failed, :invalid_frame}}

    encode_error = %{state | websocket: {:encode_error, self()}}

    assert MintSocketTransport.send_frame(encode_error, {:text, "bad"}) ==
             {:error, {:slack_socket_transport, :closed}}

    assert :ok = MintSocketTransport.close(state)
  end

  test "accepts unique keyword options and rejects invalid injected modules" do
    assert MintSocketTransport.connect(http: {:error, :offline}, requester: Requester) ==
             {:error, :offline}

    assert MintSocketTransport.connect(%{
             http: :http,
             mint_http: __MODULE__,
             mint_websocket: FakeWebSocket,
             requester: Requester
           }) == {:error, {:invalid_slack_socket_transport, :fields}}

    assert MintSocketTransport.connect(%{
             http: :http,
             mint_http: "invalid",
             mint_websocket: FakeWebSocket,
             requester: Requester
           }) == {:error, {:invalid_slack_socket_transport, :fields}}

    assert MintSocketTransport.connect(%{http: :http, requester: "invalid"}) ==
             {:error, {:invalid_slack_socket_transport, :fields}}
  end

  defp fake_options, do: fake_options("/link/?ticket=secret", %{})
  defp fake_options(path) when is_binary(path), do: fake_options(path, %{})

  defp fake_options(overrides) when is_map(overrides),
    do: fake_options("/link/?ticket=secret", overrides)

  defp fake_options(path, overrides) do
    Map.merge(
      %{
        http:
          {:ok,
           %{
             body: %{"ok" => true, "url" => "wss://wss-primary.slack.com#{path}"},
             status: 200
           }},
        mint_http: FakeHTTP,
        mint_websocket: FakeWebSocket,
        requester: Requester
      },
      overrides
    )
  end
end
