import Config

world_eval? = System.get_env("RYKER_WORLD_EVAL") == "1"

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

config :ryker, Ryker.Repo,
  database: System.get_env("PGDATABASE", "ryker_test"),
  hostname: System.get_env("PGHOST", "127.0.0.1"),
  password: System.get_env("PGPASSWORD", "postgres"),
  pool: repo_pool,
  pool_size: repo_pool_size,
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  queue_interval: 10_000,
  queue_target: 5_000,
  username: System.get_env("PGUSER", "postgres")

config :logger, level: :warning

config :ryker, :credential_key, :binary.copy(<<73>>, 32)

# Voice messages are transcribed by a deterministic stand-in: no test runs a
# speech model.
config :ryker, :transcriber, Ryker.TestTranscriber

# Emisar is answered by its recorded double: no test reaches Emisar. A
# catalog read gives up sooner than in production, so the test of an Emisar
# that does not answer in time takes a moment rather than four seconds. At
# 300 ms an ordinary read of the double ran out on a loaded machine and
# failed the gate (2026-10-04); hanging.example holds far longer than this.
config :ryker, :emisar_requester, Ryker.TestSupport.EmisarMCP
config :ryker, :emisar_catalog_budget_ms, 1_500

# What the knowledge lane and setup read from GitHub answers from replies each
# test records: no test reaches GitHub.
config :ryker, :github_files_requester, Ryker.TestSupport.RecordedGitHub

# The check a working copy's review runs is read from the repository's
# .agent/project.yaml (Ryker.CoopFleet.JobCheck); tests read none unless they
# name a reader.
config :ryker, :job_check_reader, Ryker.TestSupport.NoProjectFile
