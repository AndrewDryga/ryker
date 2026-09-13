defmodule Ryker.Repo.Migrations.CreateEpisodeRoutingDigests do
  use Ecto.Migration

  # Routing compares evidence, not the newest timestamp. A digest is the
  # host-maintained, source-backed summary of one episode: what it is about,
  # which resources and identifiers its retained inputs actually named, which
  # signals it owns, and how far its coverage reaches. It is derived from
  # retained inputs in the admitting transaction, never from a model, and it is
  # indexed so a bounded cross-conversation search can rank before truncating.
  def up do
    create table(:episode_routing_digests, primary_key: false) do
      add(
        :episode_id,
        references(:episode_kernel_episodes, type: :uuid, on_delete: :delete_all),
        primary_key: true
      )

      add(:objective, :text, null: false)
      add(:latest_development, :text)
      add(:search_text, :text, null: false)
      add(:anchor_keys, {:array, :text}, null: false, default: [])
      add(:conversation_refs, {:array, :text}, null: false, default: [])
      add(:input_count, :integer, null: false, default: 0)
      add(:covered_through_sequence, :bigint, null: false)
      add(:covered_through_at, :utc_datetime_usec, null: false)
      add(:latest_revision, :bigint, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:episode_routing_digests, [:anchor_keys], using: :gin))

    create(
      index(:episode_routing_digests, ["to_tsvector('simple', search_text)"],
        using: :gin,
        name: :episode_routing_digest_search
      )
    )

    create(
      constraint(:episode_routing_digests, :episode_routing_digest_valid,
        check:
          "char_length(objective) > 0 AND char_length(search_text) > 0 AND " <>
            "input_count >= 0 AND covered_through_sequence > 0 AND latest_revision > 0 AND " <>
            "cardinality(anchor_keys) <= 64 AND cardinality(conversation_refs) <= 32"
      )
    )
  end

  def down do
    # Digests are derived from retained admitted inputs and are rebuilt on the
    # next admission, so no original evidence is lost by dropping them.
    drop(table(:episode_routing_digests))
  end
end
