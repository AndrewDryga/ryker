defmodule Ryker.Repo.Migrations.AllowDroppedLearningBatches do
  use Ecto.Migration

  # A learning batch a person drops (Andrew, 2026-09-27: "why I can't just
  # forget/delete it?"). A batch stuck on a learned topic that lost its own
  # messages could only wait until that topic was relearned; now a person may
  # stop learning from its messages instead. The batch keeps its attempts and
  # the starts they used, and reads as dropped (`Ryker.Learning.Batches`).
  #
  # Going back turns a dropped batch into the stopped batch it was, which
  # needs a person again.

  @state """
  status IN (%{statuses})
  AND execution_mode IN ('live', 'shadow')
  AND budget_version >= 0
  AND start_limit >= 1
  AND start_count >= 0 AND start_count <= start_limit
  AND input_count >= 1 AND input_count <= 16
  AND ((status = 'running' AND lease_ref IS NOT NULL AND lease_owner IS NOT NULL
        AND lease_expires_at IS NOT NULL)
    OR (status <> 'running' AND lease_ref IS NULL AND lease_owner IS NULL
        AND lease_expires_at IS NULL))
  """

  @statuses ~w(queued running applied no_change deferred superseded)

  def up, do: replace_state(@statuses ++ ["dropped"])

  def down do
    execute("UPDATE #{qualified()} SET status = 'deferred' WHERE status = 'dropped'")
    replace_state(@statuses)
  end

  defp replace_state(statuses) do
    drop(constraint(:conversation_learning_batches, :learning_batch_state_valid))

    create(
      constraint(:conversation_learning_batches, :learning_batch_state_valid,
        check: String.replace(@state, "%{statuses}", Enum.map_join(statuses, ", ", &"'#{&1}'"))
      )
    )
  end

  defp qualified do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."conversation_learning_batches")
  end
end
