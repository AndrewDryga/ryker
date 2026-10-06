defmodule Ryker.Repo.Migrations.IndexCurrentMessageRevisions do
  use Ecto.Migration

  # Every console page that shows a message shows its current revision: the
  # highest revision of its native id, the latest recorded among equals. No
  # index held revisions in that order, so finding them ranked every revision
  # in the inbox, four times for each Activity load and again for every Chat
  # refresh, case file and request title. A conversation's messages are read
  # by its reference in the order they arrived, which no index served either
  # (2026-10-04 review).

  def change do
    create(
      index(
        :ingress_inbox_entries,
        [:native_input_id, :execution_mode, "revision DESC", "inserted_at DESC", "id DESC"],
        name: :ingress_inbox_current_revisions
      )
    )

    create(
      index(:ingress_inbox_entries, [:destination_conversation_ref, :inserted_at, :id],
        name: :ingress_inbox_conversation_order
      )
    )
  end
end
