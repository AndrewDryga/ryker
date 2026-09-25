defmodule Ryker.Repo.Migrations.AddPublicationDiscardedReason do
  use Ecto.Migration

  # Why Ryker ended a publication itself. A worker session that closed for
  # good can never be reviewed, so the host discards that request instead of
  # asking the closed session again every minute, and says so here. A person's
  # discard leaves it empty: that decision is in the operator audit.
  def up do
    alter table(:episode_publications) do
      add(:discarded_reason, :text)
    end

    create(
      constraint(:episode_publications, :episode_publication_discarded_reason_valid,
        check:
          "discarded_reason IS NULL OR " <>
            "(status = 'discarded' AND discarded_reason IN ('review_session_closed'))"
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified_publications()}
        WHERE discarded_reason IS NOT NULL
        LIMIT 1
      ) THEN
        RAISE EXCEPTION 'publication discard reasons have data and cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    drop(constraint(:episode_publications, :episode_publication_discarded_reason_valid))

    alter table(:episode_publications) do
      remove(:discarded_reason)
    end
  end

  defp qualified_publications do
    case prefix() do
      nil -> "episode_publications"
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".episode_publications)
    end
  end
end
