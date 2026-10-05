defmodule Ryker.Repo.Migrations.KeepFactsSaidOutsideSlackWhereTheyWereSaid do
  use Ecto.Migration

  # A fact a person said about themselves outside Slack was used wherever they
  # asked next, so a statement in a private repository's pull request could
  # reach a public one (2026-10-04 review). Only a public Slack channel lets a
  # fact travel now, and facts already kept from elsewhere stay where they
  # were said too.
  def up do
    execute("""
    UPDATE person_facts
    SET private = true
    WHERE NOT private AND conversation_ref NOT LIKE 'slack:%'
    """)
  end

  def down, do: :ok
end
