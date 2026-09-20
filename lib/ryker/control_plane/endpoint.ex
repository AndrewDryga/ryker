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
  plug(Plug.Session, @session_options)
  plug(Ryker.ControlPlane.WebRouter)
end
