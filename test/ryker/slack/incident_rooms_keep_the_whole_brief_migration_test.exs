defmodule Ryker.Slack.IncidentRoomsKeepTheWholeBriefMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @version 20_261_005_190_000

  # A room kept 4,000 characters of a brief an offer may make 32,000 long, so
  # an offer with a longer brief could never get its room (2026-10-05). The
  # check is rebuilt whole, so the test holds the rest of it unchanged.
  test "a room keeps the brief an offer may carry, and nothing else in its check moves" do
    assert :ok = migrate_down(@version)
    before = definition()
    assert before =~ "(char_length(prompt) <= 4000)"

    assert :ok = migrate_up(@version)

    assert definition() ==
             String.replace(
               before,
               "(char_length(prompt) <= 4000)",
               "(char_length(prompt) <= 32000)"
             )
  end

  defp definition do
    %{rows: [[definition]]} =
      SQL.query!(
        Repo,
        "SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'slack_incident_room_valid'",
        []
      )

    definition
  end
end
