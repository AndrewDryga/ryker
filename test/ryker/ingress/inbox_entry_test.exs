defmodule Ryker.Ingress.InboxEntryTest do
  use ExUnit.Case, async: true
  alias Ryker.Ingress.Inbox.Entry

  test "a source lock cannot be reused for another conversation or input revision" do
    entry = %Entry{
      id: Ecto.UUID.generate(),
      destination_transport: "slack",
      destination_conversation_ref: "slack:TEVAL:CEVAL",
      source_item_ref: "1791926113.866679",
      native_input_id: "correction:retained",
      revision: 1
    }

    assert Entry.same_source?(entry, entry)

    refute Entry.same_source?(entry, %{entry | destination_conversation_ref: "slack:TEVAL:COTHER"})

    refute Entry.same_source?(entry, %{entry | revision: 2})
    refute Entry.same_source?(entry, %{entry | native_input_id: "correction:another"})

    # Pruning is rechecked separately under the review lock. It must not turn
    # the input into a different source and conceal why it is unauthorized.
    assert Entry.same_source?(entry, %{entry | operational_pruned_at: DateTime.utc_now()})
  end
end
