defmodule Ryker.Text do
  @moduledoc """
  Cutting text to a byte budget.

  Slack, GitHub and the database enforce their limits in bytes, so a value cut
  to fit one is cut in bytes. A cut counted in characters and checked in bytes
  failed on any multi-byte text and on the "…" it added: a task card stopped
  refreshing on a long check reason (2026-10-04 review). The cut never splits a
  character.
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
