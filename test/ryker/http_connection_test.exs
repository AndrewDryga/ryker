defmodule Ryker.HTTPConnectionTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Ryker.HTTPConnection

  # A refusal is usually answered through the conn from before the body was
  # read, which leaves Bandit draining the body again from the next request
  # on the connection. The real-socket proof is in the control-plane router
  # test; this pins which responses close their connection.
  test "a refused request that carried a body closes its HTTP/1 connection" do
    refused =
      conn(:post, "/", "body") |> HTTPConnection.close_after_refusal() |> send_resp(422, "")

    assert get_resp_header(refused, "connection") == ["close"]

    accepted =
      conn(:post, "/", "body") |> HTTPConnection.close_after_refusal() |> send_resp(202, "")

    assert get_resp_header(accepted, "connection") == []

    # Without a body there is nothing to drain twice.
    missing = conn(:get, "/") |> HTTPConnection.close_after_refusal() |> send_resp(404, "")
    assert get_resp_header(missing, "connection") == []

    # HTTP/2 streams are independent and forbid a connection header.
    stream =
      conn(:post, "/", "body")
      |> put_http_protocol(:"HTTP/2")
      |> HTTPConnection.close_after_refusal()
      |> send_resp(422, "")

    assert get_resp_header(stream, "connection") == []
  end
end
