defmodule Ryker.ControlPlane.SignInGate do
  @moduledoc """
  Nobody uses the console without signing in. Andrew, 2026-10-13: Cloudflare and Tailscale only
  carry the console to a browser, so a request through a tunnel reaches Ryker just as one
  from a browser on this machine does, and where it came from says nothing about who sent it.

  The endpoint runs this after the session and before routing. A request is let through when
  it is someone (`Viewer.from_conn/2`, which it keeps on the request for everything after it),
  or when it asks for one of the few things nobody needs to sign in for: health and readiness,
  the stylesheets and pictures, and signing in. The watchdog reads `/metrics` at a loopback
  name; anywhere else metrics need a person too. A page asked for without a sign-in is sent to
  `/sign-in`, which brings the person back to it afterwards; anything else is refused.
  A page's live socket is held to the same rule where the page mounts (`WorkbenchLive.mount/3`).
  """
  @behaviour Plug
  import Plug.Conn
  alias Ryker.ControlPlane.{BrowserGuard, Endpoint, Viewer}

  # Where a page asked for before signing in is kept until the sign-in.
  @return_key "sign_in_return"
  @maximum_return 2_048

  @impl true
  def init(options), do: options

  @impl true
  def call(conn, _options) do
    conn = fetch_session(conn)
    viewer = Viewer.from_conn(conn, Endpoint.config(:control_plane))
    conn = Viewer.resolved(conn, viewer)

    cond do
      viewer -> conn
      open?(conn) -> conn
      page?(conn) -> to_sign_in(conn)
      true -> refuse(conn)
    end
  end

  @doc "The session key a page asked for before signing in is kept under."
  @spec return_key() :: String.t()
  def return_key, do: @return_key

  @doc """
  Whether `path` is a console page to return to after signing in: one absolute path of this
  console, never another site's.
  """
  @spec return_path?(term()) :: boolean()
  def return_path?(path) when is_binary(path) do
    byte_size(path) in 1..@maximum_return and String.starts_with?(path, "/") and
      not String.starts_with?(path, "//") and not String.contains?(path, ["\\", "\r", "\n"])
  end

  def return_path?(_path), do: false

  defp open?(%Plug.Conn{path_info: ["healthz"]}), do: true
  defp open?(%Plug.Conn{path_info: ["readyz"]}), do: true
  defp open?(%Plug.Conn{path_info: ["metrics"], host: host}), do: BrowserGuard.local_host?(host)
  defp open?(%Plug.Conn{path_info: ["assets" | _rest]}), do: true
  defp open?(%Plug.Conn{path_info: ["sign-in" | _rest]}), do: true
  defp open?(_conn), do: false

  defp page?(%Plug.Conn{method: method}), do: method in ["GET", "HEAD"]

  defp to_sign_in(conn) do
    path =
      if conn.query_string == "",
        do: conn.request_path,
        else: conn.request_path <> "?" <> conn.query_string

    conn = if return_path?(path), do: put_session(conn, @return_key, path), else: conn

    conn
    |> put_resp_header("location", "/sign-in")
    |> send_resp(303, "")
    |> halt()
  end

  defp refuse(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("connection", "close")
    |> send_resp(403, "Sign in to Ryker's console first: /sign-in\n")
    |> halt()
  end
end
