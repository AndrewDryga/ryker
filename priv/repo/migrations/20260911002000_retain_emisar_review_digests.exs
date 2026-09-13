defmodule Ryker.Repo.Migrations.RetainEmisarReviewDigests do
  use Ecto.Migration

  # The monitor repaints one Slack message on a real change. Until now a change
  # meant the remote RUN status, so a review that moved from "0 of 2" to a
  # granted quorum while the run stayed pending_approval repainted nothing. The
  # digest of the last presented review receipt is what makes that visible
  # without repainting on every poll.
  def up do
    alter table(:episode_emisar_approvals) do
      add(:review_digest, :text)
    end

    create(
      constraint(:episode_emisar_approvals, :episode_emisar_approval_review_valid,
        check: "review_digest IS NULL OR review_digest ~ '^[0-9a-f]{64}$'"
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified("episode_emisar_approvals")}
        WHERE review_digest IS NOT NULL
        LIMIT 1
      ) THEN
        RAISE EXCEPTION 'presented Emisar review receipts have data and cannot be rolled back safely';
      END IF;
    END
    $$
    """)

    drop(constraint(:episode_emisar_approvals, :episode_emisar_approval_review_valid))

    alter table(:episode_emisar_approvals) do
      remove(:review_digest)
    end
  end

  defp qualified(table) do
    case prefix() do
      nil -> table
      prefix -> ~s("#{String.replace(prefix, "\"", "\"\"")}".#{table})
    end
  end
end
