defmodule Ryker.Settings.ModelFallbacksMigrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :ryker,
      adapter: Ecto.Adapters.Postgres
  end

  @before_version 20_260_926_121_000
  @fallbacks_version 20_260_926_154_500
  @migrations_path Path.expand("../../../priv/repo/migrations", __DIR__)
  @kinds ~w(routing conversation standard deep contributor schedule incident learning)

  # Each kind of work saved one model; it now saves a list, the model first
  # and then its fallbacks. Every installation has a saved row, and some chose
  # their own models and accounts (Coop's own ladders run on @oncall), so the
  # upgrade must keep each saved model as the only one in its list and list
  # the accounts those models already run on. Without them every save of the
  # Models page would refuse the models the worker is running now.
  test "the migration keeps every saved model and lists the accounts they run on" do
    repo = start_migration_repo!()
    prefix = "model_fallbacks_#{System.unique_integer([:positive])}"
    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      Ecto.Migrator.run(repo, @migrations_path, :up,
        to: @before_version,
        prefix: prefix,
        log: false
      )

      SQL.query!(
        repo,
        """
        INSERT INTO #{prefix}.installation_settings (host_ref, revision, saved_by, saved_at, inserted_at)
        VALUES ('host-models', 1, 'operator:test', now(), now())
        """,
        []
      )

      saved = %{
        "routing" => "codex:gpt-5.6-terra/low@oncall",
        "conversation" => "codex:gpt-5.6-terra/medium@default",
        "standard" => "codex:gpt-5.6-sol/high@default",
        "deep" => "codex:gpt-5.6-sol/xhigh@default",
        "contributor" => "codex:gpt-5.6-sol/medium@default",
        "schedule" => "codex:gpt-5.6-luna/low@default",
        "incident" => "codex:gpt-5.6-sol/high@oncall",
        "learning" => "codex:gpt-5.6-luna/medium@default"
      }

      singles = Enum.map_join(@kinds, ", ", &"#{&1}_model")
      lists = Enum.map_join(@kinds, ", ", &"#{&1}_models")

      SQL.query!(
        repo,
        "INSERT INTO #{prefix}.work_settings (id, workspace_ref, #{singles}) " <>
          "VALUES ('host-models', 'workers', #{Enum.map_join(1..8, ", ", &"$#{&1}")})",
        Enum.map(@kinds, &saved[&1])
      )

      assert @fallbacks_version in Ecto.Migrator.run(repo, @migrations_path, :up,
               to: @fallbacks_version,
               prefix: prefix,
               log: false
             )

      assert %{rows: [["workers", ["codex@default", "codex@oncall"] | models]]} =
               SQL.query!(
                 repo,
                 "SELECT workspace_ref, model_accounts, #{lists} FROM #{prefix}.work_settings",
                 []
               )

      assert models == Enum.map(@kinds, &[saved[&1]])
      refute column_exists?(repo, prefix, "work_settings", "routing_model")

      # A new row starts where a new installation does.
      assert {:error, [["codex@default"], ["codex:gpt-5.6-sol/medium@default"]]} =
               repo.transaction(fn ->
                 SQL.query!(repo, "DELETE FROM #{prefix}.work_settings", [])

                 SQL.query!(
                   repo,
                   "INSERT INTO #{prefix}.work_settings (id) VALUES ('host-models')",
                   []
                 )

                 %{rows: [row]} =
                   SQL.query!(
                     repo,
                     "SELECT model_accounts, routing_models FROM #{prefix}.work_settings",
                     []
                   )

                 repo.rollback(row)
               end)

      # The database refuses a list the worker could not run, and takes one it can.
      sol = "codex:gpt-5.6-sol/medium@default"

      for {column, value} <- [
            {"routing_models", []},
            {"routing_models", [nil]},
            {"routing_models", ["codex:gpt-5.6-sol/max@default"]},
            {"routing_models", ["gemini:gemini-3-pro/low@default"]},
            {"routing_models", List.duplicate(sol, 5)},
            {"model_accounts", []},
            {"model_accounts", ["default"]}
          ] do
        assert_raise Postgrex.Error, ~r/work_settings_#{column}_valid/, fn ->
          SQL.query!(repo, "UPDATE #{prefix}.work_settings SET #{column} = $1", [value])
        end
      end

      SQL.query!(
        repo,
        "UPDATE #{prefix}.work_settings SET routing_models = $1, model_accounts = $2",
        [[saved["routing"], "claude:claude-opus-4-6/high@work"], ["codex@oncall", "claude@work"]]
      )

      SQL.query!(repo, "UPDATE #{prefix}.work_settings SET routing_models = $1", [
        [saved["routing"]]
      ])

      # The previous release keeps one Codex model per kind of work. Rolling
      # back while a list holds a fallback, or starts with a Claude model,
      # would drop a model someone chose, so it is refused until they are gone.
      for models <- [
            ["codex:gpt-5.6-sol/xhigh@default", "codex:gpt-5.6-sol/xhigh@oncall"],
            ["claude:claude-opus-4-6/high@work"]
          ] do
        SQL.query!(repo, "UPDATE #{prefix}.work_settings SET deep_models = $1", [models])

        assert_raise Postgrex.Error, ~r/keep one Codex model/, fn ->
          Ecto.Migrator.run(repo, @migrations_path, :down, step: 1, prefix: prefix, log: false)
        end
      end

      SQL.query!(repo, "UPDATE #{prefix}.work_settings SET deep_models = $1", [[saved["deep"]]])

      assert Ecto.Migrator.run(repo, @migrations_path, :down, step: 1, prefix: prefix, log: false) ==
               [@fallbacks_version]

      assert %{rows: [["workers" | singles_back]]} =
               SQL.query!(
                 repo,
                 "SELECT workspace_ref, #{singles} FROM #{prefix}.work_settings",
                 []
               )

      assert singles_back == Enum.map(@kinds, &saved[&1])
      refute column_exists?(repo, prefix, "work_settings", "model_accounts")

      assert_raise Postgrex.Error, ~r/work_settings_routing_model_valid/, fn ->
        SQL.query!(
          repo,
          "UPDATE #{prefix}.work_settings SET routing_model = 'claude:claude-opus-4-6/high@work'",
          []
        )
      end
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  defp column_exists?(repo, prefix, table, column) do
    %{rows: [[exists?]]} =
      SQL.query!(
        repo,
        """
        SELECT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
        )
        """,
        [prefix, table, column]
      )

    exists?
  end

  defp start_migration_repo! do
    config =
      Ryker.Repo.config()
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({MigrationRepo, config})
    MigrationRepo
  end
end
