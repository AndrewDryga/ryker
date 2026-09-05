defmodule Responder.ControlPlane.SlackMarkdown do
  alias Responder.ControlPlane.SlackNames
  @moduledoc "Small, HTML-inert renderer for the formatting used by Slack specimens."

  @tokens ~r/(```[\s\S]*?```|`[^`\n]+`|<[@#][UWCGD][A-Z0-9]+(?:\|[^>\n]+)?>|<https?:\/\/[^>\n]+>|\*[^*\n]+\*|_[^_\n]+_|~[^~\n]+~)/u
  @mentions ~r/(<[@#][UWCGD][A-Z0-9]+(?:\|[^>\n]+)?>)/u

  def mentions(text, workspace) when is_binary(text) do
    @mentions
    |> Regex.split(text, include_captures: true)
    |> Enum.map(fn part ->
      if Regex.match?(@mentions, part), do: token(part, workspace), else: escape(part)
    end)
  end

  def render(text, workspace \\ SlackNames.workspace())
      when is_binary(text) do
    @tokens
    |> Regex.split(text, include_captures: true)
    |> Enum.map(fn part ->
      if Regex.match?(@tokens, part), do: token(part, workspace), else: escape(part)
    end)
  end

  defp token("<" <> <<prefix, rest::binary>>, workspace) when prefix in [?@, ?#] do
    ref = rest |> String.trim_trailing(">") |> String.split("|", parts: 2) |> hd()
    name = SlackNames.name(workspace, ref)

    [
      "<span class=\"slack-mention\" title=\"",
      escape(ref),
      "\">",
      if(prefix == ?@, do: "@", else: ""),
      escape(name),
      "</span>"
    ]
  end

  defp token(text, _workspace), do: token(text)

  defp token("```" <> text),
    do: ["<pre><code>", escape(String.slice(text, 0..-4//1)), "</code></pre>"]

  defp token("`" <> text), do: ["<code>", escape(String.slice(text, 0..-2//1)), "</code>"]
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

  defp token(text), do: escape(text)

  defp wrapped(tag, text),
    do: ["<", tag, ">", escape(String.slice(text, 0..-2//1)), "</", tag, ">"]

  defp escape(text), do: Plug.HTML.html_escape(text)
end
