import Config

config :ryker, Ryker.Repo,
  database: System.get_env("PGDATABASE", "ryker_dev"),
  hostname: System.get_env("PGHOST", "localhost"),
  password: System.get_env("PGPASSWORD", "postgres"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  username: System.get_env("PGUSER", "postgres")

# Isolated development/test topology; never the production fleet.
config :ryker, :execution, :direct

# The durable-settings owner is driven explicitly here, never from whatever
# happens to be in the local database at boot.
config :ryker, :runtime_owner, false
