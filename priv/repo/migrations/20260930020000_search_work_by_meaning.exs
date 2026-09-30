defmodule Ryker.Repo.Migrations.SearchWorkByMeaning do
  use Ecto.Migration

  # Andrew, 2026-09-30: routing's search for earlier work "won't actually work
  # in real life". It compared words, so a Ukrainian or Spanish message, or
  # one that says the same thing in other words, never found its work. Each
  # request's digest now keeps a vector of what it is about, from a model that
  # reads a hundred languages into one space (bge-m3, run beside Ryker), and
  # routing compares the message's own vector with it.
  #
  # The vector is derived from the digest's text and cleared whenever that
  # text changes, and a worker computes it again. Rolling back drops only what
  # can be computed again.

  def change do
    alter table(:episode_routing_digests) do
      add(:embedding, {:array, :real})
      add(:embedding_model, :text)
      add(:embedded_at, :utc_datetime_usec)
    end

    create(
      constraint(:episode_routing_digests, :episode_routing_digest_embedding_valid,
        check: """
        (embedding IS NULL) = (embedding_model IS NULL)
        AND (embedding IS NULL) = (embedded_at IS NULL)
        AND (embedding IS NULL OR cardinality(embedding) BETWEEN 1 AND 4096)
        AND (embedding_model IS NULL OR char_length(embedding_model) BETWEEN 1 AND 128)
        """
      )
    )
  end
end
