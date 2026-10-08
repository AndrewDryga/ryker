defmodule Ryker.TextTest do
  use ExUnit.Case, async: true
  alias Ryker.Text

  test "a cut fits its byte budget, keeps whole characters and says it was cut" do
    assert Text.cut("short", 500) == "short"

    for text <- [
          String.duplicate("a", 600),
          String.duplicate("—", 600),
          String.duplicate("日本", 300)
        ] do
      cut = Text.cut(text, 500)
      assert byte_size(cut) <= 500
      assert String.valid?(cut)
      assert String.ends_with?(cut, "…")
    end
  end

  test "a character bound counts as PostgreSQL does and never splits what a reader sees" do
    assert Text.characters("short", 120) == "short"
    assert Text.characters(String.duplicate("é", 130), 120) == String.duplicate("é", 120)

    # A family emoji is one character on screen and seven code points to PostgreSQL.
    family = "👨‍👩‍👧‍👦"
    assert Text.characters("ab" <> family, 8) == "ab"
    assert Text.characters("ab" <> family, 9) == "ab" <> family
  end

  # Eight modules cut display text by hand, three ways: a timeline bound kept
  # its whole limit and added the ellipsis after it, and a routing note
  # measured bytes but cut characters (2026-10-08).
  test "a line shortened for display counts what a reader sees, its ellipsis included" do
    flag = "🇺🇦"

    assert Text.shorten("short", 10) == "short"
    assert Text.shorten(String.duplicate(flag, 5), 3) == flag <> flag <> "…"
    assert Text.shorten(String.duplicate("é", 101), 100) == String.duplicate("é", 99) <> "…"
  end

  test "a length counts what JSON Schema and PostgreSQL count, not what a reader sees" do
    assert Text.char_length("") == 0
    assert Text.char_length("abc") == 3
    assert Text.char_length("🇺🇦") == 2
    assert Text.char_length("e\u0301") == 2
    assert Text.char_length("👨‍👩‍👧‍👦") == 7
  end
end
