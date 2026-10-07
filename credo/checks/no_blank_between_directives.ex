defmodule Ryker.Checks.NoBlankBetweenDirectives do
  use Credo.Check,
    base_priority: :high,
    category: :readability,
    explanations: [
      check: """
      House rule: the module header is ONE contiguous block — no blank line
      between the `use` / `import` / `alias` / `require` directives, nor
      between `@moduledoc` (or `@shortdoc`, `@behaviour`) and the first of them.

          # ❌ — the default ExUnit/Phoenix shape
          use Ryker.DataCase, async: true

          alias Ryker.Episodes

          # ✅
          use Ryker.DataCase, async: true
          alias Ryker.Episodes

      The stock `StrictModuleLayout` check enforces the directive ORDER
      (`use` → `import` → `alias` → `require`) but not their contiguity; this
      catches a blank line sandwiched between two of them. Exception: the
      blank `mix format` itself inserts before a MULTI-LINE directive
      (`use Phoenix.VerifiedRoutes,\n  endpoint: …`) is left alone — fighting
      the formatter is futile.
      """
    ]

  alias Credo.Code
  alias Credo.IssueMeta
  alias Credo.SourceFile

  @directive ~r/^\s*(?:use|import|alias|require)\s/
  @header_attribute ~r/^\s*@(?:moduledoc|shortdoc|behaviour)\b/

  @impl true
  def run(%SourceFile{} = source_file, params) do
    issue_meta = IssueMeta.for(source_file, params)
    lines = code_lines(source_file)
    header_ends = header_attribute_ends(lines)

    lines
    |> Enum.chunk_every(3, 1, :discard)
    |> Enum.filter(fn [{a_no, a}, {_, blank}, {_, c}] ->
      (directive?(a) or MapSet.member?(header_ends, a_no)) and String.trim(blank) == "" and
        directive?(c) and not multiline_start?(c)
    end)
    |> Enum.map(fn [_, {blank_line_no, _}, _] -> issue_for(issue_meta, blank_line_no) end)
  end

  # A ❌ example inside a `@moduledoc`/`explanations:` heredoc is documentation,
  # not a header — blanking string bodies keeps the line numbers and stops the
  # scanner reading prose as code. Comments stay: one between two directives is
  # exactly what makes the middle line non-blank, so removing them would invent
  # a violation.
  defp code_lines(source_file) do
    source_file |> Code.clean_charlists_strings_and_sigils() |> Code.to_lines()
  end

  defp directive?(line), do: Regex.match?(@directive, line)

  # The line each `@moduledoc`, `@shortdoc` or `@behaviour` ends on: its own,
  # or the closing delimiter of its heredoc (string bodies are blanked, so the
  # next line holding the delimiter closes it).
  defp header_attribute_ends(lines) do
    lines
    |> Enum.with_index()
    |> Enum.filter(fn {{_, line}, _index} -> Regex.match?(@header_attribute, line) end)
    |> MapSet.new(fn {{line_no, line}, index} ->
      if String.contains?(line, ~s(""")),
        do: closing_line_no(lines, index),
        else: line_no
    end)
  end

  defp closing_line_no(lines, opener_index) do
    lines
    |> Enum.drop(opener_index + 1)
    |> Enum.find_value(fn {line_no, line} ->
      if line |> String.trim() |> String.starts_with?(~s(""")), do: line_no
    end)
  end

  # `mix format` puts a blank line before a directive whose options wrap onto
  # the next line (its first line ends with `,`) — don't fight that.
  defp multiline_start?(line), do: line |> String.trim_trailing() |> String.ends_with?(",")

  defp issue_for(issue_meta, line_no) do
    format_issue(
      issue_meta,
      message:
        "Blank line inside the module header — keep `@moduledoc` and the " <>
          "`use`/`import`/`alias`/`require` directives as one contiguous block.",
      line_no: line_no
    )
  end
end
