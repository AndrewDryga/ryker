import Config

config :ryker, Ryker.Repo,
  database: System.get_env("PGDATABASE", "ryker_dev"),
  hostname: System.get_env("PGHOST", "localhost"),
  password: System.get_env("PGPASSWORD", "postgres"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  username: System.get_env("PGUSER", "postgres")

# Development-only key. Production requires an independently generated
# RYKER_CREDENTIAL_KEY in runtime.exs.
config :ryker, :credential_key, :crypto.hash(:sha256, "ryker-development-credential-key")
