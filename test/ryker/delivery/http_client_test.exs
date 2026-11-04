defmodule Ryker.Delivery.HTTPClientTest do
  use ExUnit.Case, async: true
  alias Ryker.Delivery.HTTPClient

  # The tenant install, 2026-10-14: every request Ryker sends goes through one pool, and the pool
  # kept an idle connection for good. GitHub lets one go after about 30 s, and Ryker's poll every
  # 30 s went out on a connection GitHub was closing: one poll in fourteen failed with `closed`. A
  # Slack reply, or the token a Work session fetches its repositories with, meets the same
  # connection after a quiet spell, which is when a first message arrives. This server does what
  # such a server does at that moment: it takes the next request on the connection and closes it
  # unanswered.
  test "a connection idle longer than servers keep one is not reused" do
    url = "http://127.0.0.1:#{closing_server()}/"

    assert {:ok, %{status: 200, body: "first"}} = get(url)
    # The connection sits idle past the pool's limit: wall-clock time is what is under test.
    # credo:disable-for-next-line Ryker.Checks.TestNoProcessSleep
    Process.sleep(Application.fetch_env!(:ryker, :http_idle_connection_ms) + 100)
    assert {:ok, %{status: 200, body: "fresh"}} = get(url)
  end

  # One exhausted pool crashed the GitHub delivery poller on 2026-11-04.
  # Queue pressure must be retryable without taking its caller down.
  test "an exhausted connection pool remains usable after returning a retryable error" do
    pool = __MODULE__.QueueFinch
    start_supervised!({Finch, name: pool, pools: %{default: [size: 1, count: 1]}})
    url = "http://127.0.0.1:#{responding_server()}/"
    request = HTTPClient.build(:get, url)
    parent = self()

    holder =
      start_supervised!(
        {Task,
         fn ->
           result =
             Finch.stream_while(request, pool, nil, fn
               {:status, 200}, acc ->
                 send(parent, :pool_held)

                 receive do
                   :release -> {:cont, acc}
                 end

               _entry, acc ->
                 {:cont, acc}
             end)

           send(parent, {:holder_result, result})
         end},
        id: :pool_holder
      )

    on_exit(fn -> send(holder, :release) end)
    assert_receive :pool_held, 1_000

    assert HTTPClient.stream(request, pool, 2_000, 1_024) ==
             {:error, {:delivery_transport_unavailable, :pool_timeout}}

    send(holder, :release)
    assert_receive {:holder_result, {:ok, nil}}, 1_000
    assert {:ok, %{status: 200, body: "ok"}} = HTTPClient.stream(request, pool, 2_000, 1_024)
  end

  defp responding_server do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, port} = :inet.port(listen)
    on_exit(fn -> :gen_tcp.close(listen) end)

    start_supervised!(
      {Task,
       fn ->
         for _request <- 1..2 do
           {:ok, socket} = :gen_tcp.accept(listen)
           {:ok, _headers} = receive_request(socket, "")

           :ok =
             :gen_tcp.send(
               socket,
               "HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok"
             )

           :gen_tcp.close(socket)
         end
       end},
      id: :responding_server
    )

    port
  end

  defp get(url),
    do: HTTPClient.stream(HTTPClient.build(:get, url), Ryker.CoopFinch, 2_000, 1_024)

  # Answers the first request on each connection, and closes a connection that brings a second
  # request without answering it.
  defp closing_server do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, port} = :inet.port(listen)
    {:ok, _pid} = Task.start_link(fn -> accept(listen, 0) end)
    port
  end

  defp accept(listen, connection) do
    {:ok, socket} = :gen_tcp.accept(listen)
    {:ok, handler} = Task.start(fn -> serve(socket, connection) end)
    :ok = :gen_tcp.controlling_process(socket, handler)
    accept(listen, connection + 1)
  end

  defp serve(socket, connection) do
    receive_request(socket, "")
    body = if connection == 0, do: "first", else: "fresh"
    :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\n\r\n#{body}")

    with {:ok, _second} <- receive_request(socket, ""), do: :gen_tcp.close(socket)
  end

  defp receive_request(socket, received) do
    if String.contains?(received, "\r\n\r\n") do
      {:ok, received}
    else
      with {:ok, data} <- :gen_tcp.recv(socket, 0), do: receive_request(socket, received <> data)
    end
  end
end
