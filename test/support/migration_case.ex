defmodule Ryker.MigrationCase do
  @moduledoc """
  A test of one migration, run one of two ways.

  A migration that rewrites rows runs in a scratch schema of its own
  (`in_scratch_schema/2`): a repo outside the sandbox migrates the schema to
  the version before it (`migrate!/3`), the test writes rows in the shape they
  had then, migrates on and checks them, and the schema is dropped whatever
  happens.

  A migration that changes only a table's shape runs inside the test's sandbox
  transaction (`migrate_down/1`, `migrate_up/1`), which rolls it back. The
  migrator holds the one sandboxed connection, so nothing else may run beside
  it, and a migration test is never async.

  Each of the two dozen migration tests carried its own copy of these
  (2026-10-04 review).
  """
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  defmodule ScratchRepo do
    @moduledoc false
    use Ecto.Repo, otp_app: :ryker, adapter: Ecto.Adapters.Postgres
  end

  # The migrator's own lock holds the one sandboxed connection while its task
  # waits for that same connection, so it is skipped: nothing else migrates here.
  @in_sandbox [log: false, migration_lock: false]

  using do
    quote do
      @moduletag :database
      import Ryker.MigrationCase
      alias Ryker.Repo
    end
  end

  setup tags do
    if tags[:async], do: raise(ArgumentError, "a migration test cannot run async")

    owner = Sandbox.start_owner!(Ryker.Repo, shared: true)
    on_exit(fn -> Sandbox.stop_owner(owner) end)
  end

  @doc """
  Runs `fun` with a repo outside the sandbox and an empty scratch schema named
  after `name`, and drops the schema whatever happens.
  """
  @spec in_scratch_schema(String.t(), (module(), String.t() -> result)) :: result
        when result: term()
  def in_scratch_schema(name, fun) when is_binary(name) and is_function(fun, 2) do
    config =
      Ryker.Repo.config()
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({ScratchRepo, config})
    prefix = "#{name}_#{System.unique_integer([:positive])}"
    SQL.query!(ScratchRepo, "CREATE SCHEMA #{prefix}", [])

    try do
      fun.(ScratchRepo, prefix)
    after
      SQL.query!(ScratchRepo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  @doc "Migrates the scratch schema `prefix` up to `version`; the versions it ran."
  @spec migrate!(module(), String.t(), pos_integer()) :: [pos_integer()]
  def migrate!(repo, prefix, version),
    do:
      Ecto.Migrator.run(repo, Ryker.TestMigrations.all(), :up,
        to: version,
        prefix: prefix,
        log: false
      )

  @doc "Rolls the scratch schema `prefix` back by one migration; the version it undid."
  @spec rollback!(module(), String.t()) :: [pos_integer()]
  def rollback!(repo, prefix),
    do:
      Ecto.Migrator.run(repo, Ryker.TestMigrations.all(), :down,
        step: 1,
        prefix: prefix,
        log: false
      )

  @doc "Runs the migration at `version` up inside the test's sandbox transaction."
  @spec migrate_up(pos_integer()) :: :ok | :already_up
  def migrate_up(version),
    do: Ecto.Migrator.up(Ryker.Repo, version, migration(version), @in_sandbox)

  @doc "Runs the migration at `version` down inside the test's sandbox transaction."
  @spec migrate_down(pos_integer()) :: :ok | :already_down
  def migrate_down(version),
    do: Ecto.Migrator.down(Ryker.Repo, version, migration(version), @in_sandbox)

  @doc "The module of the migration at `version`, compiled once a run (`Ryker.TestMigrations`)."
  @spec migration(pos_integer()) :: module()
  def migration(version) do
    {^version, module} = List.keyfind(Ryker.TestMigrations.all(), version, 0)
    module
  end
end
