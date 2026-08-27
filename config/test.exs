import Config

config :responder, Responder.Repo,
  database: System.get_env("PGDATABASE", "responder_test"),
  hostname: System.get_env("PGHOST", "127.0.0.1"),
  password: System.get_env("PGPASSWORD", "postgres"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2,
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  queue_interval: 10_000,
  queue_target: 5_000,
  username: System.get_env("PGUSER", "postgres")

config :logger, level: :warning
