defmodule Ryker.Ingress.IndexCurrentMessageRevisionsMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @version 20_261_006_120_000
  @revisions_index "ingress_inbox_current_revisions"
  @conversation_index "ingress_inbox_conversation_order"

  # A message's current revision was found by ranking every revision in the
  # inbox, and a conversation's messages by reading every message, on every
  # page that showed one (2026-10-04 review). Each needs an index in the order
  # its query reads. The planner's choice is not asserted: on a near-empty
  # table it priced the older source-revisions index and a sort the same as
  # this one, and the pick flipped between gate runs (2026-10-08).
  test "a message's current revision and a conversation's messages each have an index in their order" do
    assert migrate_down(@version) == :ok
    assert definition(@revisions_index) == nil
    assert definition(@conversation_index) == nil

    assert migrate_up(@version) == :ok

    assert definition(@revisions_index) =~
             "(native_input_id, execution_mode, revision DESC, inserted_at DESC, id DESC)"

    assert definition(@conversation_index) =~ "(destination_conversation_ref, inserted_at, id)"
  end

  defp definition(name) do
    %{rows: rows} =
      SQL.query!(
        Repo,
        "SELECT indexdef FROM pg_indexes WHERE schemaname = current_schema() AND indexname = $1",
        [name]
      )

    rows |> List.flatten() |> List.first()
  end
end
