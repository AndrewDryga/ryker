defmodule Ryker.ControlPlane.BrowserGuard do
  @moduledoc """
  The browser boundary every control-plane response crosses: local hosts and
  either loopback peers or, in a container, its own loopback and the one
  address published traffic arrives from, plus the response headers that keep
  a page from being framed, cached, or read across origins.

  The endpoint runs it before routing, so pages, assets and the HTTP contracts
  are guarded alike; `Router` runs it again so a direct call to the HTTP router
  holds the same line. Phoenix answers the live socket before the endpoint's
  plugs, so `LiveSocket` holds it there with `peer_allowed?/2` and
  `local_host?/2`. There is one copy of the host list, the loopback test and
  the header set, here.

  Published through Cloudflare Access, the console answers at its published
  host only with a token Access signed for it (`CloudflareAccess`): a request
  there without one did not come through Access.
  """
  import Plug.Conn
  alias Ryker.ControlPlane.{CloudflareAccess, Endpoint}

  @hosts ["localhost", "127.0.0.1", "::1"]
  @content_security_policy "default-src 'none'; style-src 'self'; script-src 'self'; connect-src 'self'; img-src 'self'; font-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"

  def init(options), do: options

  def call(conn, options) do
    conn = headers(conn)
    {access, published_host, cloudflare_access} = boundary(options)

    cond do
      not local_host?(conn.host, published_host) ->
        refuse(conn, 421, "Misdirected request")

      not peer_allowed?(conn.remote_ip, access) ->
        refuse(conn, 403, "Loopback access only")

      true ->
        sign_in(conn, published_host, cloudflare_access)
    end
  end

  @doc """
  Whether `host` is one of the names the control plane answers to: the loopback names, and the
  host of the address it is published at, such as a tailnet name.
  """
  def local_host?(host, published_host \\ nil)

  # Bandit keeps the brackets of an IPv6 Host header (`[::1]`), as RFC 3986 writes one; a URI's
  # host, such as the published address's, has none.
  def local_host?("[" <> _ = host, published_host),
    do: String.ends_with?(host, "]") and local_host?(String.slice(host, 1..-2//1), published_host)

  def local_host?(host, published_host),
    do: host in @hosts or (is_binary(published_host) and host == published_host)

  def loopback?({127, _, _, _}), do: true
  def loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def loopback?(_address), do: false

  @doc """
  Whether a peer is admitted by the listener topology selected at bootstrap. In
  a container that is its own loopback and the one address published traffic
  arrives from; any other container on the network, such as a box running model
  work, is not the console's.
  """
  def peer_allowed?(address, :loopback), do: loopback?(address)

  def peer_allowed?(address, {:network, published}) when is_tuple(published),
    do: loopback?(address) or address == published

  # Under Access, a request at the published host needs a token Access signed.
  # The person it names stays on the request (`CloudflareAccess.viewer/2`), so
  # no later step checks the signature again: the router's own guard, the
  # person the request acts for and each action's record of who took it each
  # did, up to four RSA checks for one click (2026-10-04 review).
  defp sign_in(%Plug.Conn{host: host} = conn, host, %{} = cloudflare_access) do
    case CloudflareAccess.viewer(conn, cloudflare_access) do
      {:ok, viewer} -> CloudflareAccess.signed_in(conn, viewer)
      :error -> refuse(conn, 403, "Sign in through Cloudflare Access")
    end
  end

  defp sign_in(conn, _published_host, _cloudflare_access), do: conn

  defp boundary(options) do
    case Keyword.get(options, :access, :loopback) do
      :endpoint ->
        control_plane = Endpoint.config(:control_plane)

        {Map.get(control_plane, :access, :loopback), Map.get(control_plane, :public_host),
         Map.get(control_plane, :cloudflare_access)}

      access when access == :loopback or (is_tuple(access) and elem(access, 0) == :network) ->
        {access, Keyword.get(options, :public_host), Keyword.get(options, :cloudflare_access)}
    end
  end

  defp headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("content-security-policy", @content_security_policy)
    |> put_resp_header("cross-origin-resource-policy", "same-origin")
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-ryker-version", to_string(Application.spec(:ryker, :vsn) || "unknown"))
  end

  # A refusal is answered before any body is read; keeping the connection open
  # had the server drain whatever the refused client sent (2026-10-04 review).
  defp refuse(conn, status, body) do
    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("connection", "close")
    |> send_resp(status, body)
    |> halt()
  end
end
