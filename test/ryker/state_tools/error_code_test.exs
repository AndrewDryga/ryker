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
end
