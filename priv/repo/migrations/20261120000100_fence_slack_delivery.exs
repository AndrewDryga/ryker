defmodule Ryker.Repo.Migrations.FenceSlackDelivery do
  use Ecto.Migration

  def up do
    alter table(:episode_work_turns) do
      add(:slack_write_started_at, :utc_datetime_usec)
      add(:slack_write_lease_ref, :text)
      add(:thread_receipt, :map)
      add(:thread_update_checkpoint, :map)
    end

    drop(constraint(:episode_kernel_events, :episode_kernel_event_kind_valid))

    create(
      constraint(:episode_kernel_events, :episode_kernel_event_kind_valid,
        check:
          "kind IN ('input_admitted', 'owner_transferred', 'input_wait_started', 'event_wait_started', 'wait_resumed', 'result_accepted', 'delivery_confirmed', 'delivery_suppressed', 'episode_cancelled', 'reaction_recorded')"
      )
    )
  end
end
