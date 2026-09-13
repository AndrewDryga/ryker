defmodule Ryker.ControlPlane.BrowserGuard do
  @moduledoc """
  The browser boundary every control-plane response crosses: loopback peers
  and local hosts only, and the response headers that keep a page from being
  framed, cached, or read across origins.

  The endpoint runs it before routing, so live pages, assets and the HTTP
  contracts are guarded alike; `Router` runs it again so a direct call to the
  HTTP router holds the same line. There is one copy of the host list, the
  loopback test and the header set, here.
  """
  import Plug.Conn

  @hosts ["localhost", "127.0.0.1", "::1"]
  @content_security_policy "default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self'; font-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"

  def init(options), do: options

  def call(conn, _options) do
    conn = headers(conn)

    cond do
      not local_host?(conn.host) -> refuse(conn, 421, "Misdirected request")
      not loopback?(conn.remote_ip) -> refuse(conn, 403, "Loopback access only")
      true -> conn
    end
  end

  @doc "Whether `host` is one of the names the control plane answers to."
  def local_host?(host), do: host in @hosts

  def loopback?({127, _, _, _}), do: true
  def loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def loopback?(_address), do: false

  defp headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("content-security-policy", @content_security_policy)
    |> put_resp_header("cross-origin-resource-policy", "same-origin")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-ryker-version", to_string(Application.spec(:ryker, :vsn) || "unknown"))
  end

  defp refuse(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, body)
    |> halt()
  end
end
