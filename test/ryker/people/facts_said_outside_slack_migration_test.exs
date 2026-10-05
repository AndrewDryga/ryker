defmodule Ryker.People.FactsSaidOutsideSlackMigrationTest do
  use Ryker.MigrationCase

  alias Ecto.Adapters.SQL

  @version 20_261_005_160_000

  # A fact said on GitHub or in Chat was used wherever the person asked next,
  # so a statement in a private repository's pull request could reach a public
  # one (2026-10-04 review). Facts kept before the rule changed stay where
  # they were said as well; a public Slack channel's fact still travels.
  test "a fact already kept from outside Slack stays where it was said" do
    assert :ok = migrate_down(@version)

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

    assert :ok = migrate_up(@version)

    assert SQL.query!(Repo, "SELECT person_ref, private FROM person_facts ORDER BY person_ref").rows ==
             [["github:user:octo-dev", true], ["slack:user:UPUBLIC", false]]
  end
end
