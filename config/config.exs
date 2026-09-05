import Config

config :responder, ecto_repos: [Responder.Repo]

config :responder, Responder.ControlPlane.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: Responder.ControlPlane.ErrorHTML], layout: false],
  pubsub_server: Responder.ControlPlane.PubSub,
  live_view: [signing_salt: "responder-control-plane"]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
