defmodule Responder.Repo.Migrations.IndexWaitListOrder do
  use Ecto.Migration

  def change do
    # The live list refreshes every five seconds. Keep active waits ahead of
    # resolved history without sorting the entire wait archive on each refresh.
    create(
      index(:episode_event_subscriptions, [:status, "updated_at DESC", "id DESC"],
        name: :episode_event_subscriptions_list_order
      )
    )
  end
end
