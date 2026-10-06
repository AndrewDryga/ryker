defmodule Ryker.Slack.Renderer.BlocksTest do
  use ExUnit.Case, async: true

  alias Ryker.Slack.Renderer.Blocks

  # A line longer than a section is cut where it must be, but a cut inside
  # `&amp;` would show "&am" at the end of one section and "p;" at the start of
  # the next.
  test "text split across sections keeps every escape whole and loses nothing" do
    line = String.duplicate("a", 2_998) <> "&amp;" <> String.duplicate("b", 4_000)
    text = "First line &lt;kept&gt;\n" <> line

    sections = Blocks.sections(text)
    texts = Enum.map(sections, & &1["text"]["text"])

    assert Enum.all?(texts, &(String.length(&1) <= 3_000))
    refute Enum.any?(texts, &String.match?(&1, ~r/&[a-z]{0,3}\z/))
    assert texts |> Enum.join() |> String.replace("\n", "") == String.replace(text, "\n", "")
    assert Blocks.sections("Short.") == [Blocks.section("Short.")]
  end
end
