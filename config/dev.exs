import Config

config :responder, Responder.Repo,
  database: System.get_env("PGDATABASE", "responder_dev"),
  hostname: System.get_env("PGHOST", "localhost"),
  password: System.get_env("PGPASSWORD", "postgres"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  username: System.get_env("PGUSER", "postgres")
