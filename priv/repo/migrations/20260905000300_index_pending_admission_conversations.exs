defmodule Responder.Repo.Migrations.IndexPendingAdmissionConversations do
  use Ecto.Migration

  def change do
    create(
      index(
        :ingress_inbox_entries,
        [
          :destination_transport,
          :destination_conversation_ref,
          :execution_mode,
          :inserted_at,
          :id
        ],
        name: :ingress_pending_conversation_order,
        where: "status = 'pending'"
      )
    )
  end
end
