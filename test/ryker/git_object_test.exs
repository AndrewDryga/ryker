defmodule Ryker.GitObjectTest do
  use ExUnit.Case, async: true
  alias Ryker.GitObject

  # Ten modules spelled this rule two ways (2026-10-04 review); every one of
  # them now asks here, so a SHA-256 repository is accepted everywhere or
  # nowhere.
  test "an object id is 40 or 64 lowercase hex digits and nothing else" do
    assert GitObject.id?(String.duplicate("a", 40))
    assert GitObject.id?(String.duplicate("0", 64))

    for invalid <- [
          String.duplicate("a", 39),
          String.duplicate("a", 41),
          String.duplicate("a", 63),
          String.duplicate("A", 40),
          String.duplicate("g", 40),
          String.duplicate("a", 40) <> "\n",
          nil,
          42
        ] do
      refute GitObject.id?(invalid)
    end
  end
end
