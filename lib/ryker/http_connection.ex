defmodule Ryker.HTTPConnection do
  @moduledoc """
  Keeps a refused request from corrupting the next one on its connection.

  Reading a request body returns a new conn, and a `with` that refuses a
  later step answers through the conn from before the read. Bandit then
  believes the body is still unread and, to reuse an HTTP/1 connection,
  drains that many bytes again from the next request, which fails as a
  malformed request line. Every listener here answers refusals that way, so
  a refusal of a request that may carry a body closes its connection and the
  client's next request starts on a fresh one. HTTP/2 streams are
  independent and forbid a connection header, so they are left alone.
  """
  import Plug.Conn

  @doc """
  Marks a request that may carry a body to close its HTTP/1 connection when
  it is refused with a 4xx or 5xx, so the client's next request starts on a
  fresh one. `GET`, `HEAD` and HTTP/2 requests are left alone.
  """
  @spec close_after_refusal(Plug.Conn.t()) :: Plug.Conn.t()
  def close_after_refusal(%Plug.Conn{method: method} = conn) when method in ["GET", "HEAD"],
    do: conn

  def close_after_refusal(%Plug.Conn{} = conn) do
    if get_http_protocol(conn) in [:"HTTP/1", :"HTTP/1.0", :"HTTP/1.1"] do
      register_before_send(conn, fn
        %Plug.Conn{status: status} = conn when status >= 400 ->
          put_resp_header(conn, "connection", "close")

        conn ->
          conn
      end)
    else
      conn
    end
  end
end
