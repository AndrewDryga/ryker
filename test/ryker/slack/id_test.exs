defmodule Ryker.Slack.IdTest do
  # Twenty-two copies of this check until 2026-10-08, some bounded in length
  # and some not.
  use ExUnit.Case, async: true
  alias Ryker.Slack.Id

  test "an id is capital letters and digits, and short" do
    assert Id.valid?("C0BL6UCCBGR")
    assert Id.valid?("T123")
    refute Id.valid?("c0bl6uccbgr")
    refute Id.valid?("C0BL 6UC")
    refute Id.valid?("")
    refute Id.valid?(nil)
    refute Id.valid?(String.duplicate("A", 257))
  end
end
