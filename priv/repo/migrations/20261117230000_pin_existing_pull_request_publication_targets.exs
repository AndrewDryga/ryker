defmodule Ryker.Repo.Migrations.PinExistingPullRequestPublicationTargets do
  use Ecto.Migration

  def change do
    alter table(:episode_work_sessions) do
      add(:publication_target, :text)
    end

    create(
      constraint(:episode_work_sessions, :episode_work_session_publication_target_valid,
        check:
          "publication_target IS NULL OR (jsonb_typeof(publication_target::jsonb) = 'object' AND octet_length(publication_target) <= 65536)"
      )
    )
  end
end
