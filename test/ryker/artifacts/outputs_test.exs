defmodule Ryker.Artifacts.OutputsTest do
  # The validator checked an answer's artifact names with its own copy of
  # this rule until 2026-10-08.
  use ExUnit.Case, async: true
  alias Ryker.Artifacts.Outputs

  test "an output file name is one path part of 1 to 255 bytes with no control character" do
    assert Outputs.valid_name?("report.md")
    assert Outputs.valid_name?("звіт.md")
    refute Outputs.valid_name?("..")
    refute Outputs.valid_name?("a/b")
    refute Outputs.valid_name?("bad\nname")
    refute Outputs.valid_name?(String.duplicate("a", 256))
    refute Outputs.valid_name?(nil)
  end
end
