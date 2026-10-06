defmodule Ryker.Settings.SlackWorkspaceAdminsMigrationTest do
  # The DDL runs inside this test's sandbox transaction, which takes the table
  # lock, so nothing else may run beside it.
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL
  alias Ryker.Settings

  @version 20_260_926_121_000
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

    assert :ok = migrate_down(@version)

    assert saved_row() == %{
             "operators" => ["U1111111111", "U2222222222"],
             "workspace_ref" => "T0123456789"
           }

    assert :ok = migrate_up(@version)

    assert saved_row() == %{
             "operators" => ["U1111111111", "U2222222222"],
             "workspace_admins_manage" => true,
             "workspace_ref" => "T0123456789"
           }
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
