defmodule Ryker.Repo.Migrations.LeaveAFailureByHowItFails do
  use Ecto.Migration

  # A failure a person left came back on Ryker's next automatic retry, which
  # only moved its time; stopping runs, publications and approval watches
  # retry every minute (2026-10-04 review). A left failure now stays left
  # while it fails the same way. A failure left before this keeps no record of
  # how it failed, so it shows once more.
  def up do
    alter table(:failure_dismissals) do
      add(:failure_summary, :text, null: false, default: "")
      remove(:failure_updated_at)
    end

    execute("ALTER TABLE failure_dismissals ALTER COLUMN failure_summary DROP DEFAULT")

    create(
      constraint(:failure_dismissals, :failure_dismissal_summary_valid,
        check: "char_length(failure_summary) <= 1024"
      )
    )
  end

  def down do
    drop(constraint(:failure_dismissals, :failure_dismissal_summary_valid))

    alter table(:failure_dismissals) do
      add(:failure_updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
      remove(:failure_summary)
    end

    execute("ALTER TABLE failure_dismissals ALTER COLUMN failure_updated_at DROP DEFAULT")
  end
end
