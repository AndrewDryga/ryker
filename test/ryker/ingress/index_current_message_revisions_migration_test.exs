defmodule Ryker.Ingress.IndexCurrentMessageRevisionsMigrationTest do
  use Ryker.MigrationCase
  import Ecto.Query
  alias Ecto.Adapters.SQL
  alias Ryker.ControlPlane.CurrentInputQuery
  alias Ryker.Ingress.Inbox.Entry

  @version 20_261_006_120_000
  @revisions_index "ingress_inbox_current_revisions"
  @conversation_index "ingress_inbox_conversation_order"

  # A message's current revision was found by ranking every revision in the
  # inbox, and a conversation's messages by reading every message, on every
  # page that showed one (2026-10-04 review). The plans name each index once
  # it exists, read with sequential scans off so that a near-empty table does
  # not hide whether the query can use it.
  test "a message's current revision and a conversation's messages each read an index" do
    current =
      from(entry in Entry,
        as: :revision,
        inner_lateral_join: current in subquery(CurrentInputQuery.current()),
        on: true,
        where: entry.id == ^Ecto.UUID.generate(),
        select: current.id
      )

    conversation =
      from(entry in Entry,
        where: entry.destination_conversation_ref == "control-plane:lab:one",
        order_by: [asc: entry.inserted_at, asc: entry.id],
        select: entry.id
      )

    assert :ok = migrate_down(@version)
    refute plan(current) =~ @revisions_index
    refute plan(conversation) =~ @conversation_index

    assert :ok = migrate_up(@version)
    assert plan(current) =~ @revisions_index
    assert plan(conversation) =~ @conversation_index
  end

  defp plan(query) do
    SQL.query!(Repo, "SET LOCAL enable_seqscan = off", [])
    SQL.explain(Repo, :all, query)
  end
end
