defmodule Ryker.Repo.Migrations.KeepWhereGithubDeliveriesWereRead do
  use Ecto.Migration

  # Where the GitHub delivery poller stopped reading, one row per App, so a
  # restart reads on from there. It kept the place in memory, and after every
  # restart read a day of deliveries back, a thousand at most, warning that
  # older ones were skipped (2026-10-07: each deploy on an App with CI).
  def change do
    create table(:github_delivery_cursors, primary_key: false) do
      add(:app_id, :bigint, primary_key: true)
      add(:through_delivery_id, :bigint, null: false)
      add(:updated_at, :naive_datetime_usec, null: false)
    end

    create(
      constraint(:github_delivery_cursors, :github_delivery_cursor_valid,
        check: "app_id > 0 AND through_delivery_id >= 0"
      )
    )
  end
end
