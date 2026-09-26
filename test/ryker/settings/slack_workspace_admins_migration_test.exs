defmodule Ryker.Settings.SlackWorkspaceAdminsMigrationTest do
  # The DDL runs inside this test's sandbox transaction, which takes the table
  # lock, so nothing else may run beside it.
  use Ryker.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Ryker.Settings

  @version 20_260_926_120_000
  @migration Ryker.Repo.Migrations.AddSlackWorkspaceAdminsManage
  @file_name "20260926120000_add_slack_workspace_admins_manage.exs"
  # The migrator's own lock holds the one sandboxed connection while its task
  # waits for that same connection, so it is skipped: nothing else migrates here.
  @options [log: false, migration_lock: false]
  @actor "control-plane:local"

  # Andrew asked on 2026-09-26 that workspace admins and owners can manage
  # Ryker unless someone turns that off. The switch reaches installations whose
  # people were chosen long before it existed: it has to arrive on for every
  # one of them, and neither direction of the migration may lose who was
  # chosen, since that list is the only thing that says who could manage Ryker
  # before.
  test "workspace admins arrive able to manage Ryker and the chosen people survive both directions" do
    {:ok, initialized} = Settings.initialize(@actor)

    {:ok, _saved} =
      Settings.save_slack(
        %{
          enabled: true,
          workspace_ref: "T0123456789",
          bot_ref: "A0123456789",
          bot_user_ref: "U0123456789",
          operators: ["U1111111111", "U2222222222"]
        },
        initialized.installation.revision,
        @actor
      )

    assert saved_row() == %{
             "operators" => ["U1111111111", "U2222222222"],
             "workspace_admins_manage" => true,
             "workspace_ref" => "T0123456789"
           }

    assert :ok = Ecto.Migrator.down(Repo, @version, migration(), @options)

    assert saved_row() == %{
             "operators" => ["U1111111111", "U2222222222"],
             "workspace_ref" => "T0123456789"
           }

    assert :ok = Ecto.Migrator.up(Repo, @version, migration(), @options)

    assert saved_row() == %{
             "operators" => ["U1111111111", "U2222222222"],
             "workspace_admins_manage" => true,
             "workspace_ref" => "T0123456789"
           }
  end

  # `ecto.migrate` loads a migration only while it is pending, so a database
  # migrated by an earlier run leaves it for this test to load.
  defp migration do
    unless Code.ensure_loaded?(@migration) do
      :ryker
      |> Application.app_dir(Path.join("priv/repo/migrations", @file_name))
      |> Code.compile_file()
    end

    @migration
  end

  # Only the columns this change touches, read without the schema, so the
  # rolled-back table can be read at all.
  defp saved_row do
    %{columns: columns, rows: [row]} =
      SQL.query!(Repo, "SELECT * FROM slack_settings", [])

    columns
    |> Enum.zip(row)
    |> Map.new()
    |> Map.take(["operators", "workspace_admins_manage", "workspace_ref"])
  end
end
