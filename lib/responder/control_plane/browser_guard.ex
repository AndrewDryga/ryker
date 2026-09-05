defmodule Responder.ControlPlane.BrowserGuard do
  @moduledoc false
  import Plug.Conn

  def init(options), do: options

  def call(conn, _options) do
    conn =
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header(
        "content-security-policy",
        "default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
      )
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header(
        "x-responder-version",
        to_string(Application.spec(:responder, :vsn) || "unknown")
      )

    cond do
      conn.host not in ["localhost", "127.0.0.1", "::1"] ->
        conn |> send_resp(421, "Misdirected request") |> halt()

      not loopback?(conn.remote_ip) ->
        conn |> send_resp(403, "Loopback access only") |> halt()

      true ->
        conn
    end
  end

  def loopback?({127, _, _, _}), do: true
  def loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def loopback?(_address), do: false
end
