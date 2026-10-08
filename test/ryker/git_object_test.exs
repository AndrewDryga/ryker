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

  # Three publication modules each held this pattern until 2026-10-08.
  test "a branch ref is refs/heads/ and a bounded branch name" do
    assert GitObject.branch_ref?("refs/heads/main")
    assert GitObject.branch_ref?("refs/heads/ryker/fix-retries.2")
    refute GitObject.branch_ref?("main")
    refute GitObject.branch_ref?("refs/tags/v1")
    refute GitObject.branch_ref?("refs/heads/" <> String.duplicate("a", 241))
    refute GitObject.branch_ref?("refs/heads/fix retries")
    refute GitObject.branch_ref?(nil)
  end

  # The workspace checkpoint and the repository source each held this part of
  # git's rule until 2026-10-08.
  test "a part of a ref name is not empty, starts with no dot and ends in no .lock" do
    assert GitObject.ref_part?("feature")
    refute GitObject.ref_part?("")
    refute GitObject.ref_part?(".hidden")
    refute GitObject.ref_part?("main.lock")
  end
end
