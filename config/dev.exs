import Config

config :responder, Responder.Repo,
  database: System.get_env("PGDATABASE", "responder_dev"),
  hostname: System.get_env("PGHOST", "localhost"),
  password: System.get_env("PGPASSWORD", "postgres"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  username: System.get_env("PGUSER", "postgres")

# Isolated development/test topology; never the production fleet.
config :responder, :execution, :direct

# The durable-settings owner is driven explicitly here, never from whatever
# happens to be in the local database at boot.
config :responder, :runtime_owner, false
