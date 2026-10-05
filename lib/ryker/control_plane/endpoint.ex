defmodule Ryker.ControlPlane.Endpoint do
  @moduledoc "Loopback Phoenix endpoint; durable owners remain outside browser processes."
  use Phoenix.Endpoint, otp_app: :ryker

  @session_options [
    store: :cookie,
    key: "_ryker_control",
    signing_salt: "control-browser",
    same_site: "Strict",
    http_only: true
  ]

  socket("/live", Ryker.ControlPlane.LiveSocket,
    websocket: [connect_info: [:peer_data, :uri, session: @session_options]],
    longpoll: false
  )

  plug(Ryker.ControlPlane.BrowserGuard, access: :endpoint)
  plug(:session)
  plug(Ryker.ControlPlane.WebRouter)

  # Secure at the published HTTPS address, so a browser never sends the cookie
  # over plain HTTP there; it had no Secure flag (2026-10-04 review). The
  # loopback console is plain HTTP and keeps it unflagged.
  defp session(conn, _options) do
    options =
      if secure_session?(conn),
        do: [{:secure, true} | @session_options],
        else: @session_options

    Plug.Session.call(conn, Plug.Session.init(options))
  end

  defp secure_session?(%Plug.Conn{host: host}) do
    match?(%{public_host: ^host, public_https: true}, config(:control_plane))
  end
end
