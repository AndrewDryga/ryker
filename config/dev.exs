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

# Development-only key. Production requires an independently generated
# RYKER_CREDENTIAL_KEY in runtime.exs.
config :ryker, :credential_key, :crypto.hash(:sha256, "ryker-development-credential-key")
config :ryker, :github_public_url, "http://127.0.0.1:4319/v1/github"
config :ryker, :webhook_public_url, "http://127.0.0.1:4320"
