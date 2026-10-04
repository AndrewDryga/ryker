defmodule Ryker.Repo.Migrations.RememberTailnetPeople do
  use Ecto.Migration

  # Andrew, 2026-10-04, of Chat naming him "You" while Tailscale Serve said who he was: "now when
  # we have tailscale auth why not to properly track user everywhere?" What a person sends or
  # changes is recorded under their tailnet login; this keeps the name Tailscale last gave each
  # login, so a page names them on it whoever reads it.

  def change do
    create table(:control_plane_people, primary_key: false) do
      add(:login, :text, primary_key: true)
      add(:name, :text, null: false)
      add(:inserted_at, :utc_datetime_usec, null: false)
      add(:updated_at, :utc_datetime_usec, null: false)
    end

    create(
      constraint(:control_plane_people, :control_plane_people_valid,
        check: "char_length(login) BETWEEN 1 AND 200 AND char_length(name) BETWEEN 1 AND 120"
      )
    )
  end
end
