defmodule Ryker.ControlPlane.PromptDocument do
  alias Ryker.ControlPlane.RequestContextHTML
  @moduledoc "Source annotations over retained JSON tokens, without rewriting the submitted text."
  @tokens ~r/\s+|"(?:\\.|[^"\\])*"|[{}\[\],:]|[^\s{}\[\],:]+/u

  def render(%{state: :retained, truncated: false, text: text}) do
    case Jason.decode(text) do
      {:ok, value} when is_map(value) ->
        tokens = Regex.scan(@tokens, text) |> List.flatten()
        {html, rest} = value(tokens, "$", 0)
        ["<pre class=\"submitted-prompt\"><code>", html, escape(Enum.join(rest)), "</code></pre>"]

      _ ->
        pre(text)
    end
  end

  def render(%{state: :retained, text: text}), do: pre(text)
  def render(_), do: []

  defp value(tokens, path, depth) do
    {space, tokens} = Enum.split_while(tokens, &whitespace?/1)
    {html, rest} = content(tokens, path, depth)
    {[escape(Enum.join(space)), annotate(html, path)], rest}
  end

  defp content(["{" | rest], path, depth) when depth < 32 do
    {html, rest} = object(rest, path, depth + 1)
    {["{", html], rest}
  end

  # Arrays belong to their source component; their children need no duplicate labels.
  defp content(["[" | rest], path, depth) when depth < 32 do
    {html, rest} = array(rest, path, depth + 1)
    {["[", html], rest}
  end

  defp content([token | rest], _path, _depth), do: {escape(token), rest}
  defp content([], _path, _depth), do: {[], []}

  defp object(tokens, path, depth) do
    {space, tokens} = Enum.split_while(tokens, &whitespace?/1)

    case tokens do
      ["}" | rest] ->
        {[escape(Enum.join(space)), "}"], rest}

      ["," | rest] ->
        {html, rest} = object(rest, path, depth)
        {[escape(Enum.join(space)), ",", html], rest}

      [key | rest] ->
        {separator, rest} = Enum.split_while(rest, &(&1 == ":" || whitespace?(&1)))

        decoded =
          case Jason.decode(key) do
            {:ok, key} when is_binary(key) -> key
            _ -> "?"
          end

        segment =
          if Regex.match?(~r/^[A-Za-z_][A-Za-z_0-9]*$/, decoded),
            do: "." <> decoded,
            else: "[" <> Jason.encode!(decoded) <> "]"

        {html, rest} = value(rest, path <> segment, depth)
        {remaining, rest} = object(rest, path, depth)

        {[escape(Enum.join(space)), escape(key), escape(Enum.join(separator)), html, remaining],
         rest}

      [] ->
        {escape(Enum.join(space)), []}
    end
  end

  defp array(tokens, path, depth) do
    {space, tokens} = Enum.split_while(tokens, &whitespace?/1)

    case tokens do
      ["]" | rest] ->
        {[escape(Enum.join(space)), "]"], rest}

      ["," | rest] ->
        {html, rest} = array(rest, path, depth)
        {[escape(Enum.join(space)), ",", html], rest}

      [] ->
        {escape(Enum.join(space)), []}

      tokens ->
        {html, rest} = value(tokens, path <> "[]", depth)
        {remaining, rest} = array(rest, path, depth)
        {[escape(Enum.join(space)), html, remaining], rest}
    end
  end

  defp annotate(html, path) do
    if source_path?(path) do
      label = RequestContextHTML.source_label(path)

      {title, context} =
        case String.split(label, " · ", parts: 2) do
          [title, context] -> {title, context}
          [title] -> {title, "Request component"}
        end

      [
        "<span tabindex=\"0\" aria-describedby=\"prompt-inspector-tooltip\" class=\"prompt-fragment\" data-source=\"",
        escape(path),
        "\" data-source-title=\"",
        escape(title),
        "\" data-source-context=\"",
        escape(context),
        "\" data-source-path=\"",
        escape(path),
        "\">",
        html,
        "</span>"
      ]
    else
      html
    end
  end

  defp source_path?(path) do
    path in ~w($.instructions $.custom_instructions $.inputs $.knowledge) or
      Regex.match?(
        ~r/^\$\.(work|context)\.(input|inputs|current_inputs|candidates|allowed_actions|repository_ref|repository_source_kinds|destination|execution_mode|mode|offer_confirmation_supported|linked_history_ref|parent_submission_ref|responder_state_tools|source_and_action_tools|workspace|records|related_outcomes|prior_outcome|conversation_observations|conversation_knowledge|slack_addressing)$/,
        path
      ) or
      Regex.match?(
        ~r/^\$\.(work|context)\.(custom_instructions\.(global|channel)|conversation_context\.(bundle\.)?(messages|channel_summary|thread_summary)|operator_context\.[^.\[\]]+)$/,
        path
      )
  end

  defp whitespace?(token), do: String.trim(token) == ""
  defp pre(text), do: ["<pre class=\"submitted-prompt\"><code>", escape(text), "</code></pre>"]
  defp escape(text), do: Plug.HTML.html_escape(text)
end
