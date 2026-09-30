defmodule Ryker.Repo.Migrations.AskARefusedPublishAgain do
  use Ecto.Migration

  # A publish the worker was refused a grant for waited for a person, who had to
  # ask for the same change to be checked again and then approve it again: on PR
  # #2 in AndrewDryga/test (2026-09-30) the check had run under the worker's
  # earlier lease. The worker finishes a refused publish for good under its key,
  # so asking again needs a new key. This counts the publishes of one review
  # generation; every key after the first names its round.

  def change do
    alter table(:episode_publications) do
      add(:publish_round, :bigint, null: false, default: 0)
    end

    create(
      constraint(:episode_publications, :episode_publication_publish_round_valid,
        check: "publish_round >= 0"
      )
    )
  end
end
