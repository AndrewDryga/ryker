import Config

config :ryker, ecto_repos: [Ryker.Repo]

# Work placement is a property of the build, not an operator setting. Product
# builds place Work on the enrolled worker fleet; dev and test select an
# isolated topology in their own files.
config :ryker, :execution, :fleet

config :ryker, Ryker.ControlPlane.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: Ryker.ControlPlane.ErrorHTML], layout: false],
  pubsub_server: Ryker.ControlPlane.PubSub,
  live_view: [signing_salt: "ryker-control-plane"]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
