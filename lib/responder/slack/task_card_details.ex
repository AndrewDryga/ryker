defmodule Responder.Slack.TaskCardDetails do
  @moduledoc "Bounded public progress and subtasks for the pinned task card. Never private reasoning."

  @states ~w(ready working waiting completed blocked excluded cancelled)

  def valid?(task) do
    optional_text?(task["request"], 1_000) and
      items?(Map.get(task, "progress", []), 4, &progress?/1) and
      items?(Map.get(task, "goals", []), 8, &goal?/1) and goal_total?(task)
  end

  def blocks(task) do
    [
      request(task),
      progress(task["progress"] || []),
      latest(task),
      goals(task["goals"] || [], task["goals_total"], task["goals_completed"])
    ]
    |> Enum.reject(&is_nil/1)
  end

  def context(text),
    do: %{"type" => "context", "elements" => [%{"type" => "mrkdwn", "text" => text}]}

  defp request(%{"request" => request, "title" => title})
       when is_binary(request) and request != title,
       do: section("*The request*\n" <> display(request, 1_000))

  defp request(_task), do: nil

  defp latest(task) do
    progress = task["progress"] || []

    request_only? =
      progress == [] and is_binary(task["request"]) and
        String.starts_with?(task["request"], String.trim_trailing(task["summary"], "…"))

    if request_only? or get_in(List.last(progress) || %{}, ["summary"]) == task["summary"],
      do: nil,
      else: section("*Latest update*\n" <> display(task["summary"], 2_000))
  end

  defp progress([]), do: nil

  defp progress(items) do
    lines =
      Enum.map(items, fn item ->
        "#{time(item["at"])} · *#{display(item["phase"], 60)}*\n#{display(item["summary"], 600)}"
      end)

    section("*Progress*\n" <> Enum.join(lines, "\n\n"))
  end

  defp goals([], _total, _completed), do: nil

  defp goals(items, total, completed) do
    heading =
      if is_integer(completed),
        do: "#{completed} of #{total || length(items)} completed",
        else:
          "#{Enum.count(items, &(&1["state"] == "completed"))} of #{length(items)}#{if total && total > length(items), do: " shown", else: ""} completed"

    lines =
      Enum.map(items, fn item ->
        indent = if item["parent_goal_id"], do: "↳ ", else: ""

        "#{indent}#{glyph(item["state"])} #{display(item["requested_outcome"], 250)} — #{label(item["state"])}"
      end)

    coverage =
      if total && total > length(items),
        do: "\n_Showing #{length(items)} of #{total} subtasks. Open Timeline for more detail._",
        else: ""

    section(
      "*Subtasks · #{heading}*\n" <>
        Enum.join(lines, "\n") <> coverage
    )
  end

  defp progress?(item) when is_map(item) do
    Enum.sort(Map.keys(item)) == ~w(at phase summary) and text?(item["phase"], 60) and
      text?(item["summary"], 600) and datetime?(item["at"])
  end

  defp progress?(_item), do: false

  defp goal?(item) when is_map(item) do
    Enum.sort(Map.keys(item)) == ~w(id parent_goal_id requested_outcome state) and
      text?(item["id"], 120) and optional_text?(item["parent_goal_id"], 120) and
      text?(item["requested_outcome"], 250) and item["state"] in @states
  end

  defp goal?(_item), do: false

  defp goal_total?(task) do
    total = Map.get(task, "goals_total", length(Map.get(task, "goals", [])))
    completed = Map.get(task, "goals_completed")
    shown_completed = Enum.count(Map.get(task, "goals", []), &(&1["state"] == "completed"))

    is_integer(total) and total >= length(Map.get(task, "goals", [])) and total <= 1_000_000 and
      (is_nil(completed) or
         (is_integer(completed) and completed >= shown_completed and
            completed <= total - length(Map.get(task, "goals", [])) + shown_completed))
  end

  defp items?(items, maximum, valid?) when is_list(items),
    do: length(items) <= maximum and Enum.all?(items, valid?)

  defp items?(_items, _maximum, _valid?), do: false
  defp optional_text?(nil, _maximum), do: true
  defp optional_text?(text, maximum), do: text?(text, maximum)

  defp text?(text, maximum),
    do:
      is_binary(text) and String.valid?(text) and String.length(text) in 1..maximum and
        :binary.match(text, <<0>>) == :nomatch and String.trim(text) != ""

  defp section(text), do: %{"type" => "section", "text" => %{"type" => "mrkdwn", "text" => text}}
  defp datetime?(at) when is_binary(at), do: match?({:ok, _, _}, DateTime.from_iso8601(at))
  defp datetime?(_at), do: false

  defp display(text, maximum) do
    text =
      text
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

    if String.length(text) > maximum, do: String.slice(text, 0, maximum - 1) <> "…", else: text
  end

  defp time(at), do: at |> DateTime.from_iso8601() |> elem(1) |> Calendar.strftime("%H:%M UTC")
  defp glyph("completed"), do: "✓"
  defp glyph("working"), do: "▸"
  defp glyph(state) when state in ~w(blocked waiting), do: "!"
  defp glyph(state) when state in ~w(excluded cancelled), do: "−"
  defp glyph(_state), do: "○"
  defp label("ready"), do: "Ready"
  defp label("working"), do: "Working"
  defp label("waiting"), do: "Waiting"
  defp label("completed"), do: "Done"
  defp label("blocked"), do: "Blocked"
  defp label("excluded"), do: "Excluded"
  defp label("cancelled"), do: "Cancelled"
end
