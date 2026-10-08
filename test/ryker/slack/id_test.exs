defmodule Ryker.Slack.IDTest do
  # Twenty-two copies of this check until 2026-10-08, some bounded in length
  # and some not.
  use ExUnit.Case, async: true
  alias Ryker.Slack.ID

  test "an id is capital letters and digits, and short" do
    assert ID.valid?("C0BL6UCCBGR")
    assert ID.valid?("T123")
    refute ID.valid?("c0bl6uccbgr")
    refute ID.valid?("C0BL 6UC")
    refute ID.valid?("")
    refute ID.valid?(nil)
    refute ID.valid?(String.duplicate("A", 257))
  end
end
