defmodule Ryker.MarkdownCodeTest do
  use ExUnit.Case, async: true
  alias Ryker.MarkdownCode

  test "literal spans round-trip backticks, spaces, Unicode and link syntax" do
    for text <- [
          "patch(api): retry",
          "a `name`",
          "``x` [link](https://example.invalid)",
          "```",
          " leading",
          "trailing ",
          " both ",
          "café `id`"
        ] do
      wrapped = MarkdownCode.wrap(text)
      assert [{:text, ""}, {:span, ^wrapped}, {:text, ""}] = MarkdownCode.split(wrapped)
      assert MarkdownCode.contents(wrapped) == text
    end
  end

  test "code blocks stay intact while inline code and surrounding prose keep their order" do
    text = "Before `a`\n\n```sh\n# heading\n[x](y)\n```\n\nAfter."
    parts = MarkdownCode.split(text)
    assert Enum.map_join(parts, &elem(&1, 1)) == text
    assert {:block, "```sh\n# heading\n[x](y)\n```"} in parts
    assert {:span, "`a`"} in parts
  end
end
