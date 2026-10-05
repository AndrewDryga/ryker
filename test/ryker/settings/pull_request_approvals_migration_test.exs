defmodule Ryker.Settings.PullRequestApprovalsMigrationTest do
  # The DDL runs inside this test's sandbox transaction, which takes the table
  # lock, so nothing else may run beside it.
  use Ryker.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias Ryker.Settings

  @version 20_261_005_090_000
  @migration Ryker.Repo.Migrations.MakePullRequestApprovalAChoice
  @file_name "20261005090000_make_pull_request_approval_a_choice.exs"
  # The migrator's own lock holds the one sandboxed connection while its task
  # waits for that same connection, so it is skipped: nothing else migrates here.
  @options [log: false, migration_lock: false]
  @actor "control-plane:local"

  # Every repository whose App could write pull requests was granted approve
  # and merge, derived from that permission (2026-10-04 review). Once approval
  # is a choice, a grant derived before then must not count as one: the
  # repository arrives not approving, and the grants no tool uses are gone.
  test "a repository granted approval by its App's permissions arrives not approving" do
    {:ok, initialized} = Settings.initialize(@actor)

    {:ok, with_repository} =
      Settings.put_repository(
        %{ref: "widget", github_repository: "acme/widget"},
        initialized.installation.revision,
        @actor
      )

    {:ok, _bound} =
      Settings.put_github_binding(
        %{
          name: "widget-app",
          repository_ref: "widget",
          installation_id: 41,
          repository_id: 99,
          ryker_actor_id: 7,
          action_grants: ~w(read review)
        },
        with_repository.installation.revision,
        @actor
      )

    assert :ok = Ecto.Migrator.down(Repo, @version, migration(), @options)

    SQL.query!(
      Repo,
      "UPDATE github_binding_settings SET action_grants = $1 WHERE name = 'widget-app'",
      [~w(read review open_pull_request approve merge)]
    )

    assert :ok = Ecto.Migrator.up(Repo, @version, migration(), @options)

    assert saved_row() == %{
             "action_grants" => ~w(read review open_pull_request),
             "approvals_allowed" => false
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

  defp saved_row do
    %{columns: columns, rows: [row]} =
      SQL.query!(
        Repo,
        "SELECT action_grants, approvals_allowed FROM github_binding_settings",
        []
      )

    columns |> Enum.zip(row) |> Map.new()
  end
end
