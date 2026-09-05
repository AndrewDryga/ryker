defmodule Responder.ControlPlane.RequestContextHTML do
  @moduledoc "Readable context derived only from an already sanitized inspection artifact."

  def render(%{state: :retained, truncated: false, text: text}) do
    case Jason.decode(text) do
      {:ok, context} when is_map(context) -> context(context)
      _not_structured -> []
    end
  end

  def render(_artifact), do: []

  defp context(context) do
    [
      "<div class=\"request-context-readable\">",
      messages(context),
      notes("Conversation continuity", context["continuity"]),
      notes("Remembered context · potentially stale", context["operator_context"]),
      notes("Evidence and durable records", context["records"]),
      notes("Related outcomes", context["related_outcomes"]),
      candidates(context["candidates"]),
      "</div>"
    ]
  end

  defp messages(context) do
    documents =
      [context["input"], context["inputs"], context["current_inputs"]] |> Enum.reject(&is_nil/1)

    Enum.map(documents, fn document ->
      {items, omitted} =
        case document do
          %{"items" => items} when is_list(items) ->
            {items, Map.get(document, "omitted_count", 0)}

          items when is_list(items) ->
            {items, 0}

          input when is_map(input) ->
            {[input], 0}

          _invalid ->
            {[], 0}
        end

      [
        "<section><h3>Messages supplied to this request</h3>",
        Enum.map(Enum.take(items, 40), &message/1),
        if(is_integer(omitted) and omitted > 0,
          do: [
            "<p class=\"context-omission\">",
            escape(omitted),
            " earlier inputs were omitted by the submitted context budget.</p>"
          ],
          else: ""
        ),
        if(length(items) > 40,
          do:
            "<p class=\"context-omission\">More messages are available in the sanitized document below.</p>",
          else: ""
        ),
        "</section>"
      ]
    end)
  end

  defp message(input) when is_map(input) do
    actor = actor_label(input)
    body = message_text(input["content"] || input)

    [
      "<article class=\"context-message\"><header><strong>",
      escape(actor),
      "</strong><span>",
      if(input["current"] == false, do: "Earlier context", else: "Input"),
      " · ",
      escape(input["occurred_at"] || "Time not recorded"),
      "</span></header>",
      if(body,
        do: ["<div class=\"context-message-body\">", escape(body), "</div>"],
        else: "<p>Structured source event · fields below</p>"
      ),
      "<details><summary>Source fields and attachment metadata</summary><pre>",
      escape(Jason.encode!(input, pretty: true)),
      "</pre></details></article>"
    ]
  end

  defp message(_input), do: []

  defp actor_label(input) do
    actor = if is_map(input["actor"]), do: input["actor"], else: %{}

    name = actor["display_name"] || actor["name"] || input["actor_ref"] || actor["ref"]
    actor_name(name, actor)
  end

  defp actor_name("slack:user:" <> _, _actor), do: "Slack user"
  defp actor_name("github:user:" <> _, _actor), do: "GitHub user"
  defp actor_name("local-operator", _actor), do: "You · local operator"
  defp actor_name(name, _actor) when is_binary(name), do: name
  defp actor_name(_name, actor), do: human(actor["kind"] || "Source")

  defp message_text(%{"text" => text}) when is_binary(text), do: text
  defp message_text(%{"body" => text}) when is_binary(text), do: text

  defp message_text(%{} = value) do
    Enum.find_value(~w(content comment review payload), fn key -> message_text(value[key]) end)
  end

  defp message_text(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> message_text(map)
      _text -> value
    end
  end

  defp message_text(_value), do: nil

  defp notes(_title, value) when value in [nil, [], %{}], do: []

  defp notes(title, value),
    do: [
      "<section class=\"context-notes\"><h3>",
      escape(title),
      "</h3>",
      fields(value, 0),
      "</section>"
    ]

  defp fields(value, depth) when is_map(value) and depth < 5 do
    value
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, nested} ->
      [
        "<div class=\"context-field\"><h4>",
        escape(human(key)),
        "</h4>",
        fields(nested, depth + 1),
        "</div>"
      ]
    end)
  end

  defp fields(value, depth) when is_list(value) and depth < 5 do
    [
      "<ul>",
      Enum.map(Enum.take(value, 40), &["<li>", fields(&1, depth + 1), "</li>"]),
      "</ul>",
      if(length(value) > 40,
        do: "<p>Additional entries remain in the sanitized document below.</p>",
        else: ""
      )
    ]
  end

  defp fields(value, _depth) when is_map(value) or is_list(value),
    do: ["<pre>", escape(Jason.encode!(value, pretty: true)), "</pre>"]

  defp fields(nil, _depth), do: "<p class=\"context-absent\">Not supplied</p>"
  defp fields(value, _depth), do: ["<p>", escape(value), "</p>"]

  defp candidates(items) when is_list(items) and items != [] do
    [
      "<section><h3>Episodes offered to admission</h3><p>These were the allowed candidates, not a new search of today's state.</p>",
      Enum.map(Enum.take(items, 40), &candidate/1),
      "</section>"
    ]
  end

  defp candidates(_items), do: []

  defp candidate(item) when is_map(item) do
    relations =
      case item["allowed_relations"] do
        values when is_list(values) ->
          values |> Enum.filter(&is_binary/1) |> Enum.take(40) |> Enum.join(", ")

        _ ->
          "Relations not recorded"
      end

    [
      "<details class=\"context-candidate\"><summary>",
      escape(human(item["state"] || "Candidate")),
      " · ",
      escape(relations),
      "</summary>",
      fields(item, 0),
      "</details>"
    ]
  end

  defp candidate(item), do: fields(item, 0)
  defp human(value) when is_map(value) or is_list(value), do: "Structured value"
  defp human(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()
  defp escape(value) when is_map(value) or is_list(value), do: escape(Jason.encode!(value))

  defp escape(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
