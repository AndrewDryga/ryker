defmodule Ryker.ControlPlane.Endpoint do
  @moduledoc "Loopback Phoenix endpoint; durable owners remain outside browser processes."
  use Phoenix.Endpoint, otp_app: :ryker
  alias Ryker.ConsoleAccess

  # The cookie carries who is signed in, so it is Lax: it goes along when someone opens a console
  # link from another site, such as Slack in a browser, and stays behind on another site's form.
  @session_options [
    store: :cookie,
    key: "_ryker_control",
    signing_salt: "control-browser",
    same_site: "Lax",
    http_only: true
  ]

  socket("/live", Ryker.ControlPlane.LiveSocket,
    websocket: [connect_info: [:peer_data, :uri, session: @session_options]],
    longpoll: false
  )

  plug(Ryker.ControlPlane.BrowserGuard, access: :endpoint)
  plug(:session)
  plug(Ryker.ControlPlane.SignInGate)
  plug(Ryker.ControlPlane.WebRouter)

  # Secure at the published HTTPS address, so a browser never sends the cookie
  # over plain HTTP there; it had no Secure flag (2026-10-04 review). The
  # loopback console is plain HTTP and keeps it unflagged.
  #
  # The cookie lasts as long as a sign-in does, 30 days from its last use. It had
  # no lifetime, so a browser dropped it whenever it quit and the person signed in
  # again (2026-10-14). `Viewer` writes it again as the console is used.
  defp session(conn, _options) do
    options = [{:max_age, ConsoleAccess.session_seconds()} | @session_options]
    options = if secure_session?(conn), do: [{:secure, true} | options], else: options

    Plug.Session.call(conn, Plug.Session.init(options))
  end

  # A console started without a published address, as most tests start it,
  # has neither key.
  defp secure_session?(%Plug.Conn{host: host}) do
    control_plane = config(:control_plane)
    Map.get(control_plane, :public_https) == true and Map.get(control_plane, :public_host) == host
  end
end
