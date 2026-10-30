defmodule Ryker.MarkdownCode do
  @moduledoc "Literal code spans shared by knowledge documents and their Markdown preview."

  # Fences retain Slack's three-backtick form. A span closes only on a run of the
  # same length, so embedded backticks and link syntax remain literal bytes.
  @parts ~r/(?<!`)(?:```(?!`)[\s\S]*?(?<!`)```(?!`)|(?<ticks>`+)(?!`)[^\n]+?(?<!`)\k<ticks>(?!`))/u

  @doc "The code-token pattern, for a renderer that also recognizes enclosing formatting."
  def pattern, do: Regex.source(@parts)

  @doc "Wraps one line in a code span whose delimiter cannot occur in its contents."
  def wrap(text) when is_binary(text) do
    longest =
      ~r/`+/
      |> Regex.scan(text)
      |> List.flatten()
      |> Enum.map(&byte_size/1)
      |> Enum.max(fn -> 0 end)

    # Three backticks are a fence in Slack, even on one line.
    width = if longest == 2, do: 4, else: longest + 1
    delimiter = String.duplicate("`", width)

    padded =
      if longest > 0 or String.starts_with?(text, " ") or String.ends_with?(text, " "),
        do: " " <> text <> " ",
        else: text

    delimiter <> padded <> delimiter
  end

  @doc "Splits text into unchanged prose, inline spans and fenced blocks."
  def split(text) when is_binary(text) do
    {parts, offset} =
      @parts
      |> Regex.scan(text, return: :index, capture: :first)
      |> Enum.reduce({[], 0}, fn [{start, length}], {parts, offset} ->
        prose = binary_part(text, offset, start - offset)
        code = binary_part(text, start, length)

        kind =
          if String.starts_with?(code, "```") and not String.starts_with?(code, "````"),
            do: :block,
            else: :span

        {[{kind, code}, {:text, prose} | parts], start + length}
      end)

    tail = binary_part(text, offset, byte_size(text) - offset)
    Enum.reverse([{:text, tail} | parts])
  end

  @doc "The literal contents of a span returned by split/1, without its padding."
  def contents(span) when is_binary(span) do
    [delimiter] = Regex.run(~r/\A`+/, span)
    width = byte_size(delimiter)
    text = binary_part(span, width, byte_size(span) - 2 * width)

    if String.starts_with?(text, " ") and String.ends_with?(text, " ") and String.trim(text) != "",
      do: binary_part(text, 1, byte_size(text) - 2),
      else: text
  end
end
