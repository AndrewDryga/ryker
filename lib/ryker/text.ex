defmodule Ryker.Text do
  @moduledoc """
  Measuring and cutting text in the unit its limit counts.

  Slack, GitHub and the database enforce their limits in bytes, so a value cut
  to fit one is cut in bytes. A cut counted in characters and checked in bytes
  failed on any multi-byte text and on the "…" it added: a task card stopped
  refreshing on a long check reason (2026-10-04 review). The cut never splits a
  character.

  A limit in characters is JSON Schema's `maxLength` or PostgreSQL's
  `char_length`, and both count code points, not what a reader sees as one
  character: a flag is two, an accent typed after its letter makes two.
  """

  @ellipsis "…"

  @doc "`text` within `max_bytes`, ending in \"…\" when it had to be cut."
  @spec cut(String.t(), pos_integer()) :: String.t()
  def cut(text, max_bytes)
      when is_binary(text) and is_integer(max_bytes) and max_bytes >= byte_size(@ellipsis) do
    if byte_size(text) <= max_bytes,
      do: text,
      else: String.byte_slice(text, 0, max_bytes - byte_size(@ellipsis)) <> @ellipsis
  end

  @doc """
  How many characters `text` has as JSON Schema's `maxLength` and PostgreSQL's
  `char_length` count them: code points.
  """
  @spec char_length(String.t()) :: non_neg_integer()
  def char_length(text) when is_binary(text), do: text |> String.codepoints() |> length()

  @doc """
  The start of `text` within `count` characters as PostgreSQL's `char_length`
  counts them (code points), never splitting what a reader sees as one
  character.
  """
  @spec characters(String.t(), non_neg_integer()) :: String.t()
  def characters(text, count) when is_binary(text) and is_integer(count) and count >= 0 do
    text
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {kept, used} ->
      size = grapheme |> String.codepoints() |> length()

      if used + size > count,
        do: {:halt, {kept, used}},
        else: {:cont, {[grapheme | kept], used + size}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end
end
