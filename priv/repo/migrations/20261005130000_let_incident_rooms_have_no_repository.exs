defmodule Ryker.Repo.Migrations.LetIncidentRoomsHaveNoRepository do
  use Ecto.Migration

  # A conversation in no environment works without a repository, and asking
  # for an incident room there failed: a room had to name a repository
  # (2026-10-04 review). A room now keeps its conversation's repository when
  # it has one. The room check's length rule already passes a missing one.
  def up do
    execute("ALTER TABLE slack_incident_rooms ALTER COLUMN repository_ref DROP NOT NULL")
  end

  # Going back needs every room to name a repository again.
  def down do
    execute("ALTER TABLE slack_incident_rooms ALTER COLUMN repository_ref SET NOT NULL")
  end
end
