defmodule Ryker.Repo.Migrations.RecheckParkedOpenPullRequests do
  use Ecto.Migration

  # Found live 2026-09-27: after its first poll every open pull request Ryker
  # opened was parked until 9999 and checked again only when a GitHub webhook
  # arrived, and the install listens on 127.0.0.1, where none ever does. A poll
  # now puts an open pull request on a ten-minute timer
  # (`Ryker.Publication.Followups.Polls`); this makes each open one the earlier
  # releases parked due now, so its next poll starts that timer. Merged,
  # closed, stale and expired ones stay parked. No row is removed.
  #
  # Nothing to undo: under either release a due pull request is only checked.

  def up do
    execute("""
    UPDATE #{qualified("episode_publication_followups")} AS followup
    SET next_poll_at = now() AT TIME ZONE 'UTC', updated_at = now() AT TIME ZONE 'UTC'
    FROM #{qualified("episode_publications")} AS publication
    WHERE publication.id = followup.publication_id
      AND publication.status = 'published'
      AND followup.pr_state = 'open'
      AND followup.next_poll_at >= '9999-01-01'
    """)
  end

  def down, do: :ok

  defp qualified(name) do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."#{name}")
  end
end
