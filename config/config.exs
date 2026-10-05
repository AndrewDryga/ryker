import Config

config :ryker, ecto_repos: [Ryker.Repo]

# Work placement is a property of the build, not an operator setting: product
# builds place Work on the enrolled worker fleet (`:fleet`), while development
# and test run one isolated process with no fleet against a local PostgreSQL
# (`:isolated`). Those two also drive the durable-settings owner explicitly,
# never from whatever the local database holds at boot, and point the public
# URLs at the local listeners; production reads all of that from the bootstrap
# environment in runtime.exs.
if config_env() == :prod do
  config :ryker, :execution, :fleet
else
  config :ryker, :execution, :isolated
  config :ryker, :runtime_owner, false
  config :ryker, :github_public_url, "http://127.0.0.1:4319/v1/github"
  config :ryker, :webhook_public_url, "http://127.0.0.1:4320"
  config :ryker, :control_public_url, "http://127.0.0.1:4321"
end

config :ryker, Ryker.ControlPlane.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: Ryker.ControlPlane.ErrorHTML], layout: false],
  pubsub_server: Ryker.PubSub.Server,
  live_view: [signing_salt: "ryker-control-plane"]

config :phoenix, :json_library, Jason

config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Logged request and LiveView event parameters: any key containing one of these
# is replaced, which covers every token, secret and the GitHub App private key a
# settings form posts (`test/ryker/secret_inspection_test.exs` finds them).
config :phoenix, :filter_parameters, ["password", "secret", "token", "private_key"]

import_config "#{config_env()}.exs"
