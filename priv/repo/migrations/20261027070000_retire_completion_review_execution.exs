defmodule Ryker.Repo.Migrations.RetireCompletionReviewExecution do
  use Ecto.Migration

  def up do
    # The replacement has no reviewer executor or cancellation path. Never
    # strand a remote child or replay its frozen correction after upgrading.
    # Deployment pauses the only writer before migrations; the lock also
    # protects an operator running this migration directly.
    execute("""
    DO $$ BEGIN
      LOCK TABLE #{qualified("work_completion_reviews")}, #{qualified("episode_work_turns")} IN SHARE MODE;
      IF EXISTS (
        SELECT 1 FROM #{qualified("work_completion_reviews")} r
        JOIN #{qualified("episode_work_turns")} t ON t.id = r.turn_id
        WHERE r.remote_stopped_at IS NULL OR t.status IN ('pending', 'cancel_pending')
      ) THEN
        RAISE EXCEPTION 'Completion reviews must drain on the previous release before upgrading: inspect unfinished reviewers and their parent turns, then retry deployment. No history was changed.';
      END IF;
    END $$;
    """)
  end

  # This migration changes no data or schema. The old records remain owned by
  # their original retention policy and can still be inspected and reclaimed.
  def down, do: :ok

  defp qualified(table) do
    case prefix() do
      nil -> table
      schema -> ~s("#{schema}"."#{table}")
    end
  end
end
