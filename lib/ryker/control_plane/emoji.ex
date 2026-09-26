defmodule Ryker.ControlPlane.Emoji do
  @moduledoc """
  How an emoji name reads on a page: its glyph when Ryker knows the name,
  `:name:` as Slack writes it when not. Chat's reaction pills and the
  Timeline's reaction cards read names through this one table.
  """

  @glyphs %{
    "+1" => "👍",
    "thumbsup" => "👍",
    "-1" => "👎",
    "thumbsdown" => "👎",
    "heart" => "❤️",
    "eyes" => "👀",
    "tada" => "🎉",
    "rocket" => "🚀",
    "white_check_mark" => "✅",
    "heavy_check_mark" => "✔️",
    "x" => "❌",
    "warning" => "⚠️",
    "wave" => "👋",
    "pray" => "🙏",
    "raised_hands" => "🙌",
    "clap" => "👏",
    "ok_hand" => "👌",
    "fire" => "🔥",
    "sparkles" => "✨",
    "100" => "💯",
    "bulb" => "💡",
    "mag" => "🔍",
    "hourglass_flowing_sand" => "⏳",
    "thinking_face" => "🤔",
    "smile" => "😄",
    "slightly_smiling_face" => "🙂",
    "joy" => "😂",
    "muscle" => "💪"
  }

  @doc "The glyph for an emoji name, or `:name:` when Ryker does not know it."
  @spec glyph(String.t()) :: String.t()
  def glyph(name) when is_binary(name), do: Map.get(@glyphs, name, ":#{name}:")
end
