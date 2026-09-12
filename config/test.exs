import Config

repo_pool =
  if System.get_env("RESPONDER_WORLD_EVAL") == "1",
    do: DBConnection.ConnectionPool,
    else: Ecto.Adapters.SQL.Sandbox

config :responder, Responder.Repo,
  database: System.get_env("PGDATABASE", "responder_test"),
  hostname: System.get_env("PGHOST", "127.0.0.1"),
  password: System.get_env("PGPASSWORD", "postgres"),
  pool: repo_pool,
  # The pool serves test processes, not CPUs. Deriving it from the scheduler
  # count meant `ERL_FLAGS='+S 2:2'` — the usual advice for a contended host —
  # silently shrank it to four, so any test checking out four or more unboxed
  # connections failed for a reason that had nothing to do with the code.
  pool_size: 24,
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  queue_interval: 10_000,
  queue_target: 5_000,
  username: System.get_env("PGUSER", "postgres")

config :logger, level: :warning

# Isolated development/test topology; never the production fleet.
config :responder, :execution, :direct

# The durable-settings owner is driven explicitly here, never from whatever
# happens to be in the local database at boot.
config :responder, :runtime_owner, false
