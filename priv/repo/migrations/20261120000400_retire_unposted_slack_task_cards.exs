defmodule Ryker.Repo.Migrations.RetireUnpostedSlackTaskCards do
  use Ecto.Migration

  def up do
    drop(constraint(:slack_task_cards, :slack_task_card_status_valid))

    create(
      constraint(:slack_task_cards, :slack_task_card_status_valid,
        check: """
        status IN ('active', 'blocked', 'retired')
        AND (status <> 'blocked' OR (last_error_code IS NOT NULL AND next_attempt_at IS NULL AND lease_ref IS NULL))
        AND (status <> 'retired' OR (message_ref IS NULL AND next_attempt_at IS NULL AND lease_ref IS NULL))
        """
      )
    )
  end
end
