import Config

world_eval? = System.get_env("RESPONDER_WORLD_EVAL") == "1"

repo_pool = if world_eval?, do: DBConnection.ConnectionPool, else: Ecto.Adapters.SQL.Sandbox

# The pool serves test processes, not CPUs. Deriving it from the scheduler
# count meant `ERL_FLAGS='+S 2:2'` — the usual advice for a contended host —
# silently shrank it to four, so any test checking out four or more unboxed
# connections failed for a reason that had nothing to do with the code.
#
# A world-eval VM is one shard running one observation at a time and is
# model-bound: sampled twenty times mid-matrix it had zero busy connections.
# It gets the production pool of ten, because four shards at the suite's
# twenty-four would hold 96 of the 100 connections the local server allows,
# beside the 19 the production instance and its workers already hold.
repo_pool_size = if world_eval?, do: 10, else: 24

config :responder, Responder.Repo,
  database: System.get_env("PGDATABASE", "responder_test"),
  hostname: System.get_env("PGHOST", "127.0.0.1"),
  password: System.get_env("PGPASSWORD", "postgres"),
  pool: repo_pool,
  pool_size: repo_pool_size,
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
