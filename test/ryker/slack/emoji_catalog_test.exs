defmodule Ryker.Slack.EmojiCatalogTest do
  use ExUnit.Case, async: true
  alias Ryker.Slack.EmojiCatalog

  # A count alone allowed about 64 KB of names/aliases, larger than the whole
  # routing prompt once its required instructions were added. One workspace
  # catalog could therefore prevent every message from reaching admission.
  test "long names and alias targets fit a serialized byte budget together" do
    emoji =
      Map.new(1..256, fn index ->
        {String.pad_leading(Integer.to_string(index), 80, "x"),
         "alias:#{String.duplicate("y", 80)}"}
      end)

    document = EmojiCatalog.document(emoji)
    assert byte_size(Jason.encode!(document)) <= 8192
    assert document["truncated"]
    assert Map.keys(document["aliases"]) |> Enum.all?(&(&1 in document["names"]))
  end

  test "a large catalog is bounded and advertises its omitted names" do
    emoji = Map.new(1..300, &{"custom_#{&1}", "https://emoji.example/#{&1}.png"})
    document = EmojiCatalog.document(emoji)
    assert length(document["names"]) == 256
    assert document["names"] == Enum.sort(document["names"])
    assert document["truncated"]
    refute Jason.encode!(document) =~ "https://"
  end

  test "invalid names and malformed alias targets cannot enter the vocabulary" do
    document =
      EmojiCatalog.document(%{
        "plus" => "alias:heavy_plus_sign",
        "long_alias" => "alias:#{String.duplicate("x", 81)}",
        "bad name" => "https://emoji.example/a.png",
        "bad_value" => nil
      })

    assert document["names"] == ["long_alias", "plus"]
    assert document["aliases"] == %{"plus" => "heavy_plus_sign"}
  end
end
