defmodule Ryker.GitHub.InertTextTest do
  # A model's words reached GitHub able to notify people, add backlinks to
  # other repositories' issues and, in a pull request, close an issue on merge
  # ("Fixes #12"): replies and pull requests stopped only `@`, and a review the
  # model submitted stopped nothing (2026-10-04 review).
  use ExUnit.Case, async: true
  alias Ryker.GitHub.InertText

  test "no mention or issue reference survives, and the words still read the same" do
    text = "@octocat, fixes #12; see acme/api#7, gh-3 and GH-44. Issue #A and C# stay."
    inert = InertText.inert(text)

    refute inert =~ ~r/@[A-Za-z0-9]/
    refute inert =~ ~r/#\d/
    refute inert =~ ~r/\bgh-\d/i
    assert String.replace(inert, "​", "") == text
    assert inert =~ "Issue #A and C# stay."
  end
end
