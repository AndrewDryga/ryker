defmodule Ryker.ControlPlane.PromptDocument do
  @moduledoc """
  The retained prompt, formatted and read one briefing section at a time.

  Every submitted value sits inside exactly one fragment named after the
  briefing row that shows it. The prompt starts plain; the legend highlights one
  section's fragments on request, because highlighting every section at once
  made each one impossible to find.
  """
  alias Ryker.ControlPlane.Components
  alias Ryker.ControlPlane.RequestContextHTML
  alias Ryker.Crypto

  @tokens ~r/\s+|"(?:\\.|[^"\\])*"|[{}\[\],:]|[^\s{}\[\],:]+/u
  # Private-use characters mark where each part starts and ends during the walk;
  # the layout then turns them into one block per part.
  @open "\uE000"
  @close "\uE001"
  @done "\uE002"

  def render(artifact, id \\ nil)

  def render(%{state: :retained, truncated: false, text: text}, id) do
    case Jason.decode(text) do
      {:ok, value} when is_map(value) ->
        tokens = tokens(text)

        # A prompt that already contains a marker character cannot be split
        # safely; it is shown whole rather than attributed wrongly.
        parts =
          if Enum.any?(tokens, &String.contains?(&1, [@open, @close, @done])),
            do: [],
            else: RequestContextHTML.prompt_parts(value)

        indexed = Enum.with_index(parts)

        {html, rest} =
          value(tokens, "$", 0, Map.new(indexed, fn {part, index} -> {part.path, index} end))

        by_index = Map.new(indexed, fn {part, index} -> {index, part} end)

        # LiveView leaves the ignored container's children alone, so the chosen
        # highlight survives the page's periodic patches.
        [
          "<div class=\"prompt-document\" id=\"",
          Plug.HTML.html_escape(id || "prompt-document-" <> digest(text)),
          "\" phx-update=\"ignore\">",
          legend(parts, value),
          Components.copy_block_html(
            [
              "<pre class=\"submitted-prompt submitted-prompt-formatted\"><code>",
              layout([html, Plug.HTML.html_escape(Enum.join(rest))], by_index),
              "</code></pre>"
            ],
            "Copy formatted prompt"
          ),
          "</div>"
        ]

      _ ->
        pre(text)
    end
  end

  def render(%{state: :retained, text: text}, _id), do: pre(text)
  def render(_artifact, _id), do: []

  @doc "Formatted JSON for documents that are not prompts."
  def formatted(%{state: :retained, truncated: false, text: text}) do
    case Jason.decode(text) do
      {:ok, value} when is_map(value) ->
        {html, rest} = text |> tokens() |> value("$", 0, %{})

        [
          Components.copy_block_html(
            [
              "<pre class=\"submitted-prompt submitted-prompt-formatted\"><code>",
              layout([html, Plug.HTML.html_escape(Enum.join(rest))], %{}),
              "</code></pre>"
            ],
            "Copy formatted JSON"
          )
        ]

      _ ->
        pre(text)
    end
  end

  def formatted(%{state: :retained, text: text}), do: pre(text)
  def formatted(_artifact), do: []

  # Formatted in the order the model read it: routing puts its instructions
  # first, and a view that re-sorted keys would show them last.
  defp tokens(text) do
    ordered = Jason.decode!(text, objects: :ordered_objects)
    @tokens |> Regex.scan(Jason.encode!(ordered, pretty: true)) |> List.flatten()
  end

  # Sections in briefing order, each under its briefing group. A section sent
  # empty keeps its place and says so where the others give their share.
  defp legend(parts, value) do
    total = value |> Jason.encode!() |> byte_size() |> max(1)

    rows =
      parts
      |> Enum.group_by(& &1.title)
      |> Enum.map(fn {title, [first | _] = members} ->
        Map.merge(first, %{title: title, bytes: members |> Enum.map(& &1.bytes) |> Enum.sum()})
      end)
      |> Enum.sort_by(& &1.rank)
      |> Enum.chunk_by(& &1.group_label)

    [
      "<dl class=\"prompt-parts\" aria-label=\"Highlight one part of the prompt\">",
      Enum.map(rows, fn [first | _] = sections ->
        [
          "<div><dt>",
          Plug.HTML.html_escape(first.group_label),
          "</dt><dd>",
          Enum.map(sections, &chip(&1, total)),
          "</dd></div>"
        ]
      end),
      "</dl>"
    ]
  end

  defp chip(section, total) do
    [
      "<button type=\"button\" class=\"prompt-part\" data-prompt-part=\"",
      Plug.HTML.html_escape(section.title),
      "\" data-origin=\"",
      Plug.HTML.html_escape(section.origin),
      "\"",
      if(section.sent_empty?, do: " data-empty", else: []),
      " aria-pressed=\"false\" title=\"≈ ",
      Integer.to_string(ceil(section.bytes / 4)),
      " estimated tokens\">",
      Plug.HTML.html_escape(section.title),
      "<span class=\"prompt-part-share\">",
      if(section.sent_empty?, do: "empty", else: share(section.bytes, total)),
      "</span></button>"
    ]
  end

  defp share(bytes, total) do
    percent = bytes * 100 / total
    if percent < 1, do: "&lt;1%", else: "#{round(percent)}%"
  end

  defp value(tokens, path, depth, parts) do
    {space, tokens} = Enum.split_while(tokens, &whitespace?/1)
    {html, rest} = content(tokens, path, depth, parts)
    {[Plug.HTML.html_escape(Enum.join(space)), html], rest}
  end

  defp content(["{" | rest], path, depth, parts) when depth < 32 do
    {html, rest} = object(rest, path, depth + 1, parts)
    {["{", html], rest}
  end

  defp content(["[" | rest], path, depth, parts) when depth < 32 do
    {html, rest} = array(rest, path, depth + 1, 0, parts)
    {["[", html], rest}
  end

  defp content([token | rest], _path, _depth, _parts), do: {Plug.HTML.html_escape(token), rest}
  defp content([], _path, _depth, _parts), do: {[], []}

  # A member's key is highlighted with its value: a bare `2` or `null` says
  # nothing without the name it was sent under.
  defp object(tokens, path, depth, parts) do
    {space, tokens} = Enum.split_while(tokens, &whitespace?/1)

    case tokens do
      ["}" | rest] ->
        {[Plug.HTML.html_escape(Enum.join(space)), "}"], rest}

      ["," | rest] ->
        {html, rest} = object(rest, path, depth, parts)
        {[Plug.HTML.html_escape(Enum.join(space)), ",", html], rest}

      [key | rest] ->
        {separator, rest} = Enum.split_while(rest, &(&1 == ":" || whitespace?(&1)))
        child = path <> segment(key)
        {html, rest} = value(rest, child, depth, parts)
        {remaining, rest} = object(rest, path, depth, parts)
        member = [Plug.HTML.html_escape(key), Plug.HTML.html_escape(Enum.join(separator)), html]

        {[Plug.HTML.html_escape(Enum.join(space)), annotate(member, child, parts), remaining],
         rest}

      [] ->
        {Plug.HTML.html_escape(Enum.join(space)), []}
    end
  end

  defp array(tokens, path, depth, index, parts) do
    {space, tokens} = Enum.split_while(tokens, &whitespace?/1)

    case tokens do
      ["]" | rest] ->
        {[Plug.HTML.html_escape(Enum.join(space)), "]"], rest}

      ["," | rest] ->
        {html, rest} = array(rest, path, depth, index, parts)
        {[Plug.HTML.html_escape(Enum.join(space)), ",", html], rest}

      [] ->
        {Plug.HTML.html_escape(Enum.join(space)), []}

      tokens ->
        element = "#{path}[#{index}]"
        {html, rest} = value(tokens, element, depth, parts)
        {remaining, rest} = array(rest, path, depth, index + 1, parts)

        {[Plug.HTML.html_escape(Enum.join(space)), annotate(html, element, parts), remaining],
         rest}
    end
  end

  defp segment(key) do
    decoded =
      case Jason.decode(key) do
        {:ok, key} when is_binary(key) -> key
        _ -> "?"
      end

    if Regex.match?(~r/^[A-Za-z_][A-Za-z_0-9]*$/, decoded),
      do: "." <> decoded,
      else: "[" <> Jason.encode!(decoded) <> "]"
  end

  defp annotate(html, path, parts) when is_map_key(parts, path),
    do: [@open, Integer.to_string(parts[path]), @close, html, @done]

  defp annotate(html, _path, _parts), do: html

  # One row per line. Pretty-printed JSON starts and ends every part on its own
  # lines, so each line belongs to one part or to none, and a part becomes one
  # block: its colour line runs down the left edge through wrapped lines too.
  defp layout(html, parts) do
    groups =
      html
      |> IO.iodata_to_binary()
      |> String.split("\n")
      |> Enum.map_reduce(nil, &own_line/2)
      |> elem(0)
      |> Enum.chunk_by(&elem(&1, 0))

    titles = Enum.map(groups, fn [{owner, _} | _] -> owner && parts[owner].title end)

    [groups, titles, [nil | titles], tl(titles) ++ [nil]]
    |> Enum.zip()
    |> Enum.map(fn
      {lines, nil, _previous, _next} ->
        Enum.map(lines, &row/1)

      {[{owner, _} | _] = lines, title, previous, next} ->
        [
          fragment(parts[owner], previous == title, next == title),
          Enum.map(lines, &row/1),
          "</span>"
        ]
    end)
  end

  defp own_line(line, open) do
    owner =
      case Regex.run(~r/\x{E000}([0-9]+)\x{E001}/u, line, capture: :all_but_first) do
        [index] -> String.to_integer(index)
        nil -> open
      end

    text = String.replace(line, ~r/\x{E000}[0-9]+\x{E001}|\x{E002}/u, "")
    {{owner, text}, if(String.contains?(line, @done), do: nil, else: owner)}
  end

  defp row({_owner, text}), do: ["<span class=\"prompt-row\">", text, "</span>"]

  # Neighbouring parts of the same section share one unbroken colour line.
  defp fragment(part, joined_above?, joined_below?),
    do: [
      "<span tabindex=\"0\" aria-describedby=\"ryker-tooltip\" class=\"prompt-fragment\" data-part=\"",
      Plug.HTML.html_escape(part.title),
      "\" data-origin=\"",
      Plug.HTML.html_escape(part.origin),
      "\" data-source=\"",
      Plug.HTML.html_escape(part.path),
      "\" data-source-title=\"",
      Plug.HTML.html_escape(part.title),
      "\" data-source-context=\"",
      Plug.HTML.html_escape(
        if(part.sent_empty?, do: part.group_label <> " · empty", else: part.group_label)
      ),
      "\" data-source-path=\"",
      Plug.HTML.html_escape(part.path),
      "\"",
      if(joined_above?, do: " data-joined-above", else: []),
      if(joined_below?, do: " data-joined-below", else: []),
      ">"
    ]

  defp whitespace?(token), do: String.trim(token) == ""

  defp digest(text),
    do: Crypto.sha256_hex(text) |> binary_part(0, 16)

  defp pre(text) do
    Components.copy_block_html(
      [
        "<pre class=\"submitted-prompt submitted-prompt-raw\"><code>",
        Plug.HTML.html_escape(text),
        "</code></pre>"
      ],
      "Copy exact text"
    )
  end
end
