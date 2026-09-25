defmodule Ryker.Repo.Migrations.AddEpisodeTitlesToRoutingDigests do
  use Ecto.Migration

  # An episode's one-line title, written by the Work turn that named it and
  # kept beside the source-derived digest. It is the digest's one model-written
  # field: routing reads it as Ryker's own name for the work, never as evidence,
  # and it cascades and is pruned with the rest of the digest.
  def up do
    alter table(:episode_routing_digests) do
      add(:title, :text)
      add(:title_turn_id, :uuid)
      add(:title_updated_at, :utc_datetime_usec)
    end

    create(
      constraint(:episode_routing_digests, :episode_routing_digest_title_valid,
        check:
          "(title IS NULL AND title_turn_id IS NULL AND title_updated_at IS NULL) OR " <>
            "(char_length(title) BETWEEN 1 AND 80 AND title !~ '[\\n\\r]' AND " <>
            "title_turn_id IS NOT NULL AND title_updated_at IS NOT NULL)"
      )
    )
  end

  def down do
    # A title is a summary the next Work turn writes again; dropping it loses
    # no source evidence.
    drop(constraint(:episode_routing_digests, :episode_routing_digest_title_valid))

    alter table(:episode_routing_digests) do
      remove(:title_updated_at)
      remove(:title_turn_id)
      remove(:title)
    end
  end
end
