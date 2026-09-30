defmodule Ryker.Repo.Migrations.AnalyzeTasksFromTheirConversation do
  use Ecto.Migration

  # A rating on a confirmed task was refused as "improvement_evidence_automated": the task's own
  # episode holds only the go-ahead and what GitHub sent, and the person asked for the task in
  # the conversation that offered it (the PR #2 task, 2026-09-29). The evidence now reads that
  # conversation. A refused analysis never starts again by itself, so the tasks refused this way
  # are asked again; a request an alert or a schedule started stays refused.

  def up, do: execute(requeued_tasks_sql())

  def down, do: :ok

  def requeued_tasks_sql do
    """
    UPDATE improvement_candidates AS candidate
    SET analysis = 'pending', error_code = NULL,
        next_attempt_at = now() AT TIME ZONE 'utc', updated_at = now() AT TIME ZONE 'utc'
    WHERE candidate.analysis = 'failed'
      AND candidate.error_code = 'improvement_evidence_automated'
      AND candidate.forgotten_at IS NULL
      AND EXISTS (
        SELECT 1 FROM episode_state_records AS record
        WHERE record.kind = 'task_offer' AND record.confirmed_episode_id = candidate.episode_id
      )
    """
  end
end
