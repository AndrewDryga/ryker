defmodule Ryker.Repo.Migrations.LeaveFailuresAsTheyAre do
  use Ecto.Migration

  # Andrew, 2026-10-03, of a failure's "Leave it": "okay, but how do I hide the alert if I want to
  # leave it and not be annoyed by having a failure pending forever?" Leaving a failure records
  # its identity and when it last changed. Failures stops listing it until it changes again, which
  # is a new failure worth seeing; nothing about the failure itself changes. A failure that ends
  # where it lives (a learning batch dropped, a room or a request closed) needs no row here.

  def change do
    create table(:failure_dismissals, primary_key: false) do
      add(:kind, :text, primary_key: true)
      add(:ref, :text, primary_key: true)
      add(:failure_updated_at, :utc_datetime_usec, null: false)
      add(:left_by, :text, null: false)
      add(:left_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(:failure_dismissals, :failure_dismissals_valid,
        check:
          "char_length(kind) BETWEEN 1 AND 64 AND char_length(ref) BETWEEN 1 AND 1024 AND " <>
            "char_length(left_by) BETWEEN 1 AND 256"
      )
    )
  end
end
