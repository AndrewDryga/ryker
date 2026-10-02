defmodule Ryker.Repo.Migrations.CloseIncidentRoomsOnRequest do
  use Ecto.Migration

  # Andrew, 2026-10-03: "why I can't do shit to incident rooms, how about at least closing them?"
  # A room closed only when Slack deleted its channel. A person can now ask to close one from the
  # console. The request is kept on the room, and the room worker carries it out: it closes the
  # room's investigation, says so in the room and in the alert thread the room came from, then
  # closes the room. Nothing about the room or its investigation is deleted.

  def change do
    alter table(:slack_incident_rooms) do
      add(:close_requested_at, :utc_datetime_usec)
      add(:close_requested_by, :text)
    end

    create(
      constraint(:slack_incident_rooms, :slack_incident_rooms_close_request_valid,
        check:
          "(close_requested_at IS NULL AND close_requested_by IS NULL) OR " <>
            "(close_requested_at IS NOT NULL AND char_length(close_requested_by) BETWEEN 1 AND 256)"
      )
    )
  end
end
