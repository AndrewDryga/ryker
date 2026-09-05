defmodule Responder.ControlPlane.SlackMarkdown do
  @moduledoc "Small, HTML-inert renderer for the formatting used by Slack specimens."

  @tokens ~r/(```[\s\S]*?```|`[^`\n]+`|<https?:\/\/[^>\n]+>|\*[^*\n]+\*|_[^_\n]+_|~[^~\n]+~)/u

  def render(text) when is_binary(text) do
    @tokens
    |> Regex.split(text, include_captures: true)
    |> Enum.map(fn part ->
      if Regex.match?(@tokens, part), do: token(part), else: escape(part)
    end)
  end

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
