defmodule Ryker.Repo.Migrations.SearchDigestsWithEnglishStems do
  @moduledoc """
  Earlier-work search reads word forms and knows which text matters most.

  The digest search matched exact spellings in one flat text ("failing" never
  found "fail", "probes" never found "probe"). A stored vector now stems each
  field with the English dictionary and weighs them: the work's title most,
  then its objective and latest development, then its messages. Similar past
  cases get the same stemming over their own text. Both are derived columns
  or indexes; nothing is lost by rolling back.
  """
  use Ecto.Migration

  def up do
    execute("""
    ALTER TABLE #{qualified("episode_routing_digests")} ADD COLUMN search_vector tsvector
      GENERATED ALWAYS AS (
        setweight(to_tsvector('english', coalesce(title, '')), 'A') ||
        setweight(to_tsvector('english', coalesce(objective, '')), 'B') ||
        setweight(to_tsvector('english', coalesce(latest_development, '')), 'B') ||
        setweight(to_tsvector('english', coalesce(search_text, '')), 'C')
      ) STORED
    """)

    create(
      index(:episode_routing_digests, [:search_vector],
        using: :gin,
        name: :episode_routing_digest_search_vector
      )
    )

    drop(index(:episode_routing_digests, [], name: :episode_routing_digest_search))
    drop(index(:episode_case_records, [], name: :episode_case_record_search))

    create(
      index(:episode_case_records, ["to_tsvector('english', search_text)"],
        using: :gin,
        name: :episode_case_record_search
      )
    )
  end

  def down do
    drop(index(:episode_case_records, [], name: :episode_case_record_search))

    create(
      index(:episode_case_records, ["to_tsvector('simple', search_text)"],
        using: :gin,
        name: :episode_case_record_search
      )
    )

    create(
      index(:episode_routing_digests, ["to_tsvector('simple', search_text)"],
        using: :gin,
        name: :episode_routing_digest_search
      )
    )

    drop(index(:episode_routing_digests, [], name: :episode_routing_digest_search_vector))
    execute("ALTER TABLE #{qualified("episode_routing_digests")} DROP COLUMN search_vector")
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
