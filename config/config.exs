import Config

config :responder, ecto_repos: [Responder.Repo]

import_config "#{config_env()}.exs"
