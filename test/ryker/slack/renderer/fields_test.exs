defmodule Ryker.Slack.Renderer.FieldsTest do
  # The incident room card cut its text in characters for these byte checks,
  # and a goal written in Ukrainian refused the whole card (2026-10-08).
  use ExUnit.Case, async: true
  alias Ryker.Slack.Renderer.Fields

  test "a card's text is cut in the bytes the renderer checks, and no text stays none" do
    cut = Fields.cut(String.duplicate("Перевірити ", 30), 200)

    assert byte_size(cut) <= 200
    assert Fields.bounded_text(cut, 200) == :ok
    assert Fields.cut(nil, 200) == nil
  end
end
