defmodule Ryker.Settings.WorkSkillsMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  test "existing installations and environments start with an empty catalog of imports and no selections" do
    {:ok, snapshot} = Ryker.Settings.initialize("control-plane:local")

    {:ok, _snapshot} =
      Ryker.Settings.put_environment(
        %{ref: "staging", display_name: "Staging"},
        snapshot.installation.revision,
        "control-plane:local"
      )

    assert migrate_down(20_261_126_000_200) == :ok
    assert migrate_down(20_261_126_000_100) == :ok
    assert migrate_up(20_261_126_000_100) == :ok
    assert migrate_up(20_261_126_000_200) == :ok

    assert SQL.query!(Repo, "SELECT enabled_skills, installed_skills FROM work_settings").rows ==
             [[[], %{}]]

    assert SQL.query!(
             Repo,
             "SELECT enabled_skills FROM environment_settings WHERE ref = 'staging'"
           ).rows == [[[]]]
  end
end
