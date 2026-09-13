defmodule Ryker.ControlPlane.SlackMarkdown do
  alias Ryker.ControlPlane.SlackNames
  @moduledoc "Small, HTML-inert renderer for the formatting used in Slack messages."

  @tokens ~r/(```[\s\S]*?```|`[^`\n]+`|\[[^\]\n]+\]\(https?:\/\/[^\s)]+\)|<!date\^[^>\n]+\|[^>\n]+>|<[@#][UWCGD][A-Z0-9]+(?:\|[^>\n]+)?>|<https?:\/\/[^>\n]+>|\*\*[^*\n]+\*\*|\*[^*\n]+\*|(?<![\p{L}\p{N}_])_[^_\n]+_(?![\p{L}\p{N}_])|~[^~\n]+~)/u
  @mentions ~r/(<[@#][UWCGD][A-Z0-9]+(?:\|[^>\n]+)?>)/u

  def mentions(text, workspace) when is_binary(text) do
    @mentions
    |> Regex.split(text, include_captures: true)
    |> Enum.map(fn part ->
      if Regex.match?(@mentions, part), do: token(part, workspace), else: escape(part)
    end)
  end

  @doc """
  Plain text with every mention token replaced by the directory's name for it:
  "@emisar", "#test", or the descriptive fallback while a name is unresolved.
  For titles and other places that are not HTML.
  """
  def plain(text, workspace \\ SlackNames.workspace())

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

  defp mention_name(token, workspace), do: SlackNames.name(workspace, mention_ref(token))

  # The reference inside `<@U…|label>` or `<#C…|name>`, without its label.
  defp mention_ref("<" <> <<_prefix, rest::binary>>),
    do: rest |> String.trim_trailing(">") |> String.split("|", parts: 2) |> hd()

  def render(text, workspace \\ SlackNames.workspace())
      when is_binary(text) do
    @tokens
    |> Regex.split(text, include_captures: true)
    |> Enum.map(fn part ->
      if Regex.match?(@tokens, part), do: token(part, workspace), else: escape(part)
    end)
  end

  @doc "HTML-inert Markdown for human-facing answers and public progress."
  def preview(text, workspace \\ SlackNames.workspace()) when is_binary(text) do
    ~r/(```[\s\S]*?```)/u
    |> Regex.split(text, include_captures: true)
    |> Enum.map(fn
      "```" <> _ = code ->
        token(code)

      prose ->
        prose |> String.split(~r/\n\s*\n/u, trim: true) |> Enum.map(&paragraph(&1, workspace))
    end)
  end

  defp paragraph(text, workspace) do
    lines = String.split(text, "\n")

    cond do
      Enum.all?(lines, &Regex.match?(~r/^\s*[-*•] /u, &1)) ->
        [
          "<ul>",
          Enum.map(
            lines,
            &["<li>", render(Regex.replace(~r/^\s*[-*•] /u, &1, ""), workspace), "</li>"]
          ),
          "</ul>"
        ]

      Enum.all?(lines, &Regex.match?(~r/^\s*\d+\. /u, &1)) ->
        [
          "<ol>",
          Enum.map(
            lines,
            &["<li>", render(Regex.replace(~r/^\s*\d+\. /u, &1, ""), workspace), "</li>"]
          ),
          "</ol>"
        ]

      true ->
        ["<p>", render(text, workspace), "</p>"]
    end
  end

  defp token("<" <> <<prefix, _rest::binary>> = mention, workspace) when prefix in [?@, ?#] do
    ref = mention_ref(mention)
    name = SlackNames.name(workspace, ref)

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

  defp token("```" <> text),
    do: ["<pre><code>", escape(String.slice(text, 0..-4//1)), "</code></pre>"]

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

  defp wrapped(tag, text),
    do: ["<", tag, ">", escape(String.slice(text, 0..-2//1)), "</", tag, ">"]

  defp escape(text), do: Plug.HTML.html_escape(text)
end
