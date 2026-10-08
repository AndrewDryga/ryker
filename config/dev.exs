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

# Plugs initialize at runtime here and in tests, as in Emisar: initialized at
# compile time, the endpoint and router compiled in every plug, and those plugs
# reach the endpoint again at runtime, which made 124 files one compile cycle.
# Production keeps compile-time initialization.
config :phoenix, :plug_init_mode, :runtime
