defmodule Ryker.Settings.UncheckedGitHubGrantsMigrationTest do
  # The DDL runs inside this test's sandbox transaction, which takes the table
  # lock, so nothing else may run beside it.
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL
  alias Ryker.Settings

  @version 20_261_005_110_000
  @actor "control-plane:local"

  # A repository's "Allowed actions" listed opening pull requests, updating
  # Ryker's branch and issues, derived from the App's permissions, though no
  # tool ever checked them (2026-10-04 review). A stored grant nothing checks
  # goes, and a binding saved without grants starts with only checked ones.
  test "a repository's allowed actions keep only the ones a tool checks" do
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

    assert :ok = migrate_down(@version)

    SQL.query!(
      Repo,
      "UPDATE github_binding_settings SET action_grants = $1 WHERE name = 'widget-app'",
      [~w(read review open_pull_request update_ryker_branch rerun_ci cancel_ci issues)]
    )

    assert :ok = migrate_up(@version)

    assert saved_grants() == ~w(read review rerun_ci cancel_ci)

    %{rows: [[default]]} =
      SQL.query!(
        Repo,
        """
        SELECT column_default FROM information_schema.columns
        WHERE table_name = 'github_binding_settings' AND column_name = 'action_grants'
        """,
        []
      )

    refute default =~ "open_pull_request"
    refute default =~ "update_ryker_branch"
  end

  defp saved_grants do
    %{rows: [[grants]]} =
      SQL.query!(Repo, "SELECT action_grants FROM github_binding_settings", [])

    grants
  end
end
