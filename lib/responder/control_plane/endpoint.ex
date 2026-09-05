defmodule Responder.ControlPlane.Endpoint do
  @moduledoc "Loopback Phoenix endpoint; durable owners remain outside browser processes."
  use Phoenix.Endpoint, otp_app: :responder

  @session_options [
    store: :cookie,
    key: "_responder_control",
    signing_salt: "control-browser",
    same_site: "Strict",
    http_only: true
  ]

  socket("/live", Responder.ControlPlane.LiveSocket,
    websocket: [connect_info: [:peer_data, :uri, session: @session_options]],
    longpoll: false
  )

  plug(Responder.ControlPlane.BrowserGuard)
  plug(Plug.Session, @session_options)
  plug(Responder.ControlPlane.WebRouter)
end
