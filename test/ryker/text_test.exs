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
end
