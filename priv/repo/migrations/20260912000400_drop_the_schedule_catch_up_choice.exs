defmodule Responder.Repo.Migrations.DropTheScheduleCatchUpChoice do
  use Ecto.Migration

  # A schedule carried a choice about missed runs, and every surface that showed
  # a schedule had to explain it: "Missed runs — Run the latest missed
  # occurrence". Nobody wants a morning infrastructure check firing at four in
  # the afternoon because the host was down overnight, and the alternative was
  # the only sensible behaviour anyway. A missed run is now recorded as missed
  # and the next one runs on time, so there is nothing left to choose.
  def up do
    alter table(:episode_schedules) do
      remove(:catch_up)
    end
  end

  def down do
    alter table(:episode_schedules) do
      add(:catch_up, :text)
    end

    execute("UPDATE #{qualified("episode_schedules")} SET catch_up = 'skip'")
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
