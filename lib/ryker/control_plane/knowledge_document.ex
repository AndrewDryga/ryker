defmodule Ryker.ControlPlane.KnowledgeDocument do
  @moduledoc """
  A repository's knowledge (RYKER.md) as its page shows it: headings as
  headings, lists, code and emphasis as Markdown renders them
  (`Ryker.ControlPlane.SlackMarkdown.preview/2`), and each link to a path in
  the repository opened on GitHub at the commit the knowledge was written
  from. It was a block of raw Markdown, "## Purpose" and
  "[README.md](README.md)" included (Andrew, 2026-10-04: "well
  structured/formatted text").

  The document's own title, its first line when that is a level-one heading,
  is the title of the row that holds it, so it is not repeated inside.
  """
  alias Ryker.ControlPlane.SlackMarkdown
  alias Ryker.GitHub

  @heading ~r/\A(\#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*\z/u
  @fence ~r/\A[ \t]*```/u
  @code_span ~r/(`[^`\n]+`)/u
  @relative_link ~r/\[([^\]\n]+)\]\((?!https?:|mailto:|#)([^\s)]+)\)/u

  @typedoc "Where a link to a repository path goes: its GitHub name and the commit it was read at."
  @type source :: %{github_repository: String.t() | nil, commit: String.t() | nil}

  @doc """
  The document's title, when its first line is a level-one heading, and the
  rest of it as safe HTML.
  """
  @spec render(String.t(), source()) :: {String.t() | nil, Phoenix.HTML.safe()}
  def render(document, source) when is_binary(document) do
    {title, body} = title(document)
    {title, {:safe, body |> blocks() |> Enum.map(&block(&1, source))}}
  end

  defp title(document) do
    case String.split(document, "\n", parts: 2) do
      ["# " <> heading | rest] -> {String.trim(heading), Enum.join(rest)}
      _untitled -> {nil, document}
    end
  end

  # Headings outside code fences, and the text between them as it was written.
  defp blocks(text) do
    {blocks, prose, _fenced} =
      text
      |> String.split("\n")
      |> Enum.reduce({[], [], false}, fn line, {blocks, prose, fenced} ->
        cond do
          Regex.match?(@fence, line) ->
            {blocks, [line | prose], not fenced}

          not fenced and Regex.match?(@heading, line) ->
            [_line, marks, words] = Regex.run(@heading, line)
            {[{:heading, String.length(marks), words} | prose_block(prose, blocks)], [], false}

          true ->
            {blocks, [line | prose], fenced}
        end
      end)

    Enum.reverse(prose_block(prose, blocks))
  end

  defp prose_block(lines, blocks) do
    text = lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()
    if text == "", do: blocks, else: [{:prose, text} | blocks]
  end

  # A level-one heading inside the document reads one step below the row's
  # title; the levels under it follow.
  defp block({:heading, level, words}, source) do
    tag = "h#{min(level + 2, 6)}"
    ["<", tag, " class=\"knowledge-heading\">", inline(words, source), "</", tag, ">"]
  end

  defp block({:prose, text}, source), do: text |> linked(source) |> SlackMarkdown.preview()

  defp inline(words, source), do: words |> linked(source) |> SlackMarkdown.render()

  # A link to a path in the repository, written for someone reading the
  # repository itself, opens that path on GitHub at the knowledge's commit.
  # Code is left as it was written.
  defp linked(text, source) do
    @code_span
    |> Regex.split(text, include_captures: true)
    |> Enum.map_join(fn
      "`" <> _ = code -> code
      words -> Regex.replace(@relative_link, words, &link(&1, &2, &3, source))
    end)
  end

  defp link(_match, label, path, %{github_repository: repository, commit: commit})
       when is_binary(repository) and is_binary(commit) do
    kind = if String.ends_with?(path, "/"), do: "tree", else: "blob"
    path = path |> String.trim_leading("./") |> String.trim_leading("/")
    "[#{label}](#{GitHub.web_url()}/#{repository}/#{kind}/#{commit}/#{URI.encode(path)})"
  end

  defp link(_match, label, _path, _source), do: label
end
