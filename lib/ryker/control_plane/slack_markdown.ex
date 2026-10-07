defmodule Ryker.ControlPlane.SlackMarkdown do
  @moduledoc "Small, HTML-inert renderer for the formatting used in Slack messages."
  alias Ryker.ControlPlane.Kit
  alias Ryker.Slack.Names

  @tokens ~r/(```[\s\S]*?```|`[^`\n]+`|\[[^\]\n]+\]\(https?:\/\/[^\s)]+\)|<!date\^[^>\n]+\|[^>\n]+>|<[@#][UWCGD][A-Z0-9]+(?:\|[^>\n]+)?>|<https?:\/\/[^>\n]+>|\*\*[^*\n]+\*\*|\*[^*\n]+\*|(?<![\p{L}\p{N}_])_[^_\n]+_(?![\p{L}\p{N}_])|~[^~\n]+~)/u
  @mentions ~r/(<[@#][UWCGD][A-Z0-9]+(?:\|[^>\n]+)?>)/u

  @doc """
  Text with its mentions as names, for a line that sits inside a link, such
  as a row's title: a person reads as their name, not as a link of their own.
  """
  def mentions(text, workspace) when is_binary(text) do
    @mentions
    |> Regex.split(text, include_captures: true)
    |> Enum.map(fn part ->
      cond do
        not Regex.match?(@mentions, part) ->
          escape(part)

        String.starts_with?(part, "<@") ->
          [
            "<span class=\"slack-mention\">",
            escape(Names.person(workspace, mention_ref(part)).name),
            "</span>"
          ]

        true ->
          token(part, workspace)
      end
    end)
  end

  @doc """
  Plain text with every mention token replaced by the directory's name for it:
  "@emisar", "#test", or the descriptive fallback while a name is unresolved.
  For titles and other places that are not HTML.
  """
  def plain(text, workspace \\ Names.workspace())

  # Without a workspace there is no directory to ask; the token stays as the
  # message wrote it rather than becoming a meaningless "Slack reference".
  def plain(text, nil) when is_binary(text), do: text

  def plain(text, workspace) when is_binary(text) and is_binary(workspace) do
    @mentions
    |> Regex.split(text, include_captures: true)
    |> Enum.map_join(fn part ->
      if Regex.match?(@mentions, part), do: mention_name(part, workspace), else: part
    end)
  end

  defp mention_name(token, workspace), do: Names.name(workspace, mention_ref(token))

  # The reference inside `<@U…|label>` or `<#C…|name>`, without its label.
  defp mention_ref("<" <> <<_prefix, rest::binary>>),
    do: rest |> String.trim_trailing(">") |> String.split("|", parts: 2) |> hd()

  def render(text, workspace \\ Names.workspace())
      when is_binary(text) do
    @tokens
    |> Regex.split(text, include_captures: true)
    |> Enum.map(fn part ->
      if Regex.match?(@tokens, part), do: token(part, workspace), else: escape(part)
    end)
  end

  @doc "HTML-inert Markdown for human-facing answers and public progress."
  def preview(text, workspace \\ Names.workspace()) when is_binary(text) do
    ~r/(```[\s\S]*?```)/u
    |> Regex.split(text, include_captures: true)
    |> Enum.map(fn
      "```" <> _ = code ->
        token(code)

      prose ->
        prose |> String.split(~r/\n\s*\n/u, trim: true) |> Enum.map(&paragraph(&1, workspace))
    end)
  end

  # A list may start right under a line of text ("Check these first:\n1. …"),
  # so a paragraph is split into runs of plain lines, bullet lines and
  # numbered lines, each rendered as what it is. A question that listed what
  # it needed ran into one line before. An indented line under a list item
  # belongs to that item: words that wrapped continue it, and indented
  # points become a list inside it, so the list does not start over.
  defp paragraph(text, workspace) do
    text
    |> String.split("\n")
    |> items()
    |> Enum.chunk_by(fn {head, _children} -> line_kind(head) end)
    |> Enum.map(fn [{head, _children} | _] = items ->
      block(items, line_kind(head), workspace)
    end)
  end

  defp items(lines) do
    lines
    |> Enum.reduce([], fn
      line, [{head, children} | rest] = items ->
        if line_kind(head) != :text and indented?(line),
          do: [{head, children ++ [line]} | rest],
          else: [{line, []} | items]

      line, [] ->
        [{line, []}]
    end)
    |> Enum.reverse()
  end

  defp indented?(line), do: Regex.match?(~r/^(?: {2,}|\t)\S/u, line)

  @bullet ~r/^\s*[-*•] /u
  # [0-9], not \d: with the u flag \d matches any script's digits, and
  # String.to_integer/1 raises on them.
  @numbered ~r/^\s*[0-9]+\. /u

  defp line_kind(line) do
    cond do
      Regex.match?(@bullet, line) -> :bullet
      Regex.match?(@numbered, line) -> :numbered
      true -> :text
    end
  end

  defp block(items, :bullet, workspace),
    do: ["<ul>", Enum.map(items, &item(&1, @bullet, workspace)), "</ul>"]

  defp block([{head, _children} | _] = items, :numbered, workspace),
    do: [ordered_list_open(head), Enum.map(items, &item(&1, @numbered, workspace)), "</ol>"]

  defp block(items, :text, workspace),
    do: ["<p>", render(Enum.map_join(items, "\n", &elem(&1, 0)), workspace), "</p>"]

  # The item's own words, the words that wrapped under it, then any points
  # indented under it as a list of their own.
  defp item({head, children}, marker, workspace) do
    {wrapped, nested} =
      Enum.split_while(children, &(line_kind(String.trim_leading(&1)) == :text))

    words = Enum.join([Regex.replace(marker, head, "") | Enum.map(wrapped, &String.trim/1)], " ")
    ["<li>", render(words, workspace), nested_blocks(nested, workspace), "</li>"]
  end

  defp nested_blocks([], _workspace), do: []

  defp nested_blocks(lines, workspace) do
    lines
    |> Enum.map(&{String.trim_leading(&1), []})
    |> Enum.chunk_by(fn {line, _children} -> line_kind(line) end)
    |> Enum.map(fn [{line, _children} | _] = items ->
      block(items, line_kind(line), workspace)
    end)
  end

  # Items separated by blank lines arrive as separate paragraphs; each list
  # starts at the number its first item was written with, so they still count
  # 1, 2, 3 instead of starting over.
  defp ordered_list_open(first_line) do
    case Regex.run(~r/^\s*([0-9]+)\. /u, first_line) do
      [_match, "1"] ->
        "<ol>"

      [_match, number] ->
        ["<ol start=\"", number |> String.to_integer() |> Integer.to_string(), "\">"]
    end
  end

  # A person reads the one way every page shows one: their name, linked to
  # their Slack profile, never a raw ID (Andrew, 2026-09-26). A channel keeps
  # its reference for a reader to hover.
  defp token("<@" <> _ = mention, workspace),
    do: workspace |> Names.person(mention_ref(mention)) |> Kit.person_html("slack-mention")

  defp token("<#" <> _ = mention, workspace) do
    ref = mention_ref(mention)
    name = Names.name(workspace, ref)

    [
      "<span class=\"slack-mention\" title=\"",
      escape(ref),
      "\">",
      escape(name),
      "</span>"
    ]
  end

  defp token(text, _workspace), do: token(text)

  defp token("<!date^" <> text) do
    # Slack supplies a readable fallback; keep it as text, never execute the token's optional URL.
    text |> String.trim_trailing(">") |> String.split("|", parts: 2) |> List.last() |> escape()
  end

  # A fence's first word names the block's language ("```sh"); it is not
  # code. The block scrolls inside itself (.md-code) so a long line never
  # widens the page it sits on.
  defp token("```" <> text) do
    {language, code} = text |> String.slice(0..-4//1) |> fence()

    [
      "<pre class=\"md-code\"",
      if(language != "", do: [" data-language=\"", escape(language), "\""], else: []),
      "><code>",
      escape(code),
      "</code></pre>"
    ]
  end

  defp token("`" <> text), do: ["<code>", escape(String.slice(text, 0..-2//1)), "</code>"]
  defp token("**" <> text), do: ["<strong>", escape(String.slice(text, 0..-3//1)), "</strong>"]
  defp token("*" <> text), do: wrapped("strong", text)
  defp token("_" <> text), do: wrapped("em", text)
  defp token("~" <> text), do: wrapped("del", text)

  defp token("<http" <> _ = text) do
    [url | labels] = text |> String.slice(1..-2//1) |> String.split("|", parts: 2)
    uri = URI.parse(url)

    if uri.scheme in ["https", "http"] and is_binary(uri.host) and uri.host != "" and
         is_nil(uri.userinfo),
       do: [
         "<a href=\"",
         escape(url),
         "\" target=\"_blank\" rel=\"noreferrer noopener\">",
         escape(List.first(labels) || url),
         "</a>"
       ],
       else: escape(text)
  end

  defp token("[" <> text) do
    [label, url] = text |> String.trim_trailing(")") |> String.split("](", parts: 2)
    token("<" <> url <> "|" <> label <> ">")
  end

  defp token(text), do: escape(text)

  defp fence(body) do
    case Regex.run(~r/\A([A-Za-z0-9_+.#-]*)\n(.*)\z/s, body) do
      [_line, language, code] -> {language, String.trim_trailing(code, "\n")}
      nil -> {"", body}
    end
  end

  defp wrapped(tag, text),
    do: ["<", tag, ">", escape(String.slice(text, 0..-2//1)), "</", tag, ">"]

  defp escape(text), do: Plug.HTML.html_escape(text)
end
