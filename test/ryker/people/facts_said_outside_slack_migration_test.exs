defmodule Ryker.People.FactsSaidOutsideSlackMigrationTest do
  # The migrator runs inside this test's sandbox transaction, so nothing else
  # may run beside it.
  use Ryker.DataCase, async: false

  alias Ecto.Adapters.SQL

  @version 20_261_005_160_000
  @migration Ryker.Repo.Migrations.KeepFactsSaidOutsideSlackWhereTheyWereSaid
  @file_name "20261005160000_keep_facts_said_outside_slack_where_they_were_said.exs"
  # The migrator's own lock holds the one sandboxed connection while its task
  # waits for that same connection, so it is skipped: nothing else migrates here.
  @options [log: false, migration_lock: false]

  # A fact said on GitHub or in Chat was used wherever the person asked next,
  # so a statement in a private repository's pull request could reach a public
  # one (2026-10-04 review). Facts kept before the rule changed stay where
  # they were said as well; a public Slack channel's fact still travels.
  test "a fact already kept from outside Slack stays where it was said" do
    assert :ok = Ecto.Migrator.down(Repo, @version, migration(), @options)

    SQL.query!(
      Repo,
      """
      INSERT INTO person_facts
        (id, person_ref, key, fact, status, source_input_id, source_message_ref,
         conversation_ref, private, said_at)
      VALUES
        (gen_random_uuid(), 'github:user:octo-dev', 'time-zone', 'Works on Kyiv time.', 'kept',
         gen_random_uuid(), 'github-comment:74', 'github:ryker-app:octo/private-review:pull:74',
         false, '2026-10-01 08:00:00'),
        (gen_random_uuid(), 'slack:user:UPUBLIC', 'time-zone', 'Works on Lisbon time.', 'kept',
         gen_random_uuid(), 'slack-message:1', 'slack:TPEOPLE:CPUBLIC', false,
         '2026-10-01 08:00:00')
      """,
      []
    )

    assert :ok = Ecto.Migrator.up(Repo, @version, migration(), @options)

    assert SQL.query!(Repo, "SELECT person_ref, private FROM person_facts ORDER BY person_ref").rows ==
             [["github:user:octo-dev", true], ["slack:user:UPUBLIC", false]]
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
end
