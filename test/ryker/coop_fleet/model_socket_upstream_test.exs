defmodule Ryker.CoopFleet.ModelSocketUpstreamTest do
  use ExUnit.Case, async: true
  alias Ryker.CoopFleet.ModelSocketUpstream
  alias Ryker.Secret

  test "native handshake preserves real HTTP authentication and rate-limit refusals" do
    for status <- [401, 429] do
      {server, port} =
        server(fn socket, _request ->
          :ok =
            :gen_tcp.send(
              socket,
              "HTTP/1.1 #{status} Refused\r\nContent-Length: 7\r\nRetry-After: 30\r\n\r\nrefused"
            )
        end)

      assert {:error, {:provider_response, ^status, headers, "refused"}} = connect(port)
      assert {"retry-after", "30"} in headers
      Task.await(server)
    end
  end

  test "upgraded provider frames move both ways and close with their owner" do
    owner = self()

    {server, port} =
      server(fn socket, request ->
        [_, key] = Regex.run(~r/sec-websocket-key: ([^\r]+)\r/i, request)

        accept =
          :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: #{accept}\r\n\r\n"
          )

        {:ok, <<0x81, 1::1, size::7, mask::binary-size(4), payload::binary>>} =
          :gen_tcp.recv(socket, 0, 5_000)

        assert byte_size(payload) == size

        decoded =
          for {byte, index} <- payload |> :binary.bin_to_list() |> Enum.with_index(),
              into: <<>>,
              do: <<Bitwise.bxor(byte, :binary.at(mask, rem(index, 4)))>>

        send(owner, {:provider_received, decoded})
        :ok = :gen_tcp.send(socket, <<0x81, 5, "reply">>)
        assert :gen_tcp.recv(socket, 0, 5_000) == {:error, :closed}
      end)

    {:ok, upstream} = connect(port)
    assert ModelSocketUpstream.attach(upstream) == :ok
    assert ModelSocketUpstream.send_frame(upstream, {:text, "hello"}) == :ok
    assert_receive {:provider_received, "hello"}
    assert_receive {:model_socket_frame, ^upstream, {:text, "reply"}}
    GenServer.stop(upstream)
    Task.await(server)
  end

  defp connect(port) do
    ModelSocketUpstream.connect(
      %{host: "api.openai.com", path: "/v1/responses", headers: Secret.new([])},
      fn _ ->
        {:ok, conn} = Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1])
        {:ok, conn, :ws}
      end
    )
  end

  defp server(reply) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_address, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
        reply.(socket, request)
        :gen_tcp.close(socket)
        :gen_tcp.close(listener)
      end)

    {task, port}
  end
end
