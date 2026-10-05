defmodule Ryker.StateTools.ErrorCodeTest do
  use ExUnit.Case, async: true

  alias Ryker.StateTools.ErrorCode

  # A final naming a record this work never created was answered
  # "temporarily_unavailable", which the model reads as "retry the same
  # call": three checks of one reply failed that way on 2026-09-26 before it
  # went through. A mistake the model can fix gets a correction, not a retry.
  test "a reply naming a record this work did not create gets a correction, not a retry" do
    code = ErrorCode.code(:state_record_not_found)

    assert code =~ ~r/^invalid_arguments: /
    assert code =~ "record_refs"
    refute code == "temporarily_unavailable"
  end

  # The budget is the search's time and lock limit in the database. The
  # timeline told people the run had used up its searches, which no limit
  # here counts (2026-10-05).
  test "a memory search stopped by its time limit says so on the timeline" do
    assert ErrorCode.explain("memory_search_budget_exceeded") =~ "took too long"
  end

  # A lookup that reached a message queued for a later turn reads a code of
  # its own, not a retryable one.
  test "a lookup refused a queued source keeps its own code" do
    assert ErrorCode.code(:source_not_available) == "source_not_available"
    refute ErrorCode.explain("source_not_available") == "Ryker refused the call."
  end
end
