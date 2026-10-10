defmodule Ryker.ControlPlane.EmojiTest do
  use ExUnit.Case, async: true
  alias Ryker.ControlPlane.Emoji

  # A question reaction on a Chat reply showed as the text ":question:" (manual test, 2026-10-09):
  # the table knew 28 names, and people react in Slack with many more. Common names read as
  # their glyph; a name Ryker does not know, such as a workspace's custom emoji, keeps
  # Slack's :name: spelling.
  test "a common reaction reads as its glyph, and an unknown one as Slack writes it" do
    for {name, glyph} <- [
          {"question", "❓"},
          {"white_check_mark", "✅"},
          {"large_green_circle", "🟢"},
          {"point_up", "☝️"},
          {"sweat_smile", "😅"},
          {"bug", "🐛"},
          {"memo", "📝"},
          {"rotating_light", "🚨"}
        ] do
      assert Emoji.glyph(name) == glyph, "#{name} reads as #{Emoji.glyph(name)}"
    end

    assert Emoji.glyph("party_parrot") == ":party_parrot:"
  end
end
