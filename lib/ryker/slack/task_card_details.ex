defmodule Ryker.Slack.TaskCardDetails do
  @moduledoc """
  The task request and its stable stage ledger. Never private reasoning.

  The request is shown whole: Slack folds a long one behind "Show more", and
  opening it shows all of it (Andrew, 2026-09-28: "when its open I want to see
  all of it"). Progress is never folded (Block Kit's `expand`: "Progress
  should be always fully visible"). Every stage stays visible for the whole
  task; its glyph carries the current disposition. The active stage and the
  active subtask are bold, and a human handoff is marked beside the item that
  needs the person.
  """

  import Ryker.Slack.Renderer.Blocks,
    only: [escape: 1, expanded_section: 1, section: 1, truncate: 2]

  alias Ryker.Records.InvestigationPayload
  alias Ryker.Work.TaskStages

  @goal_states InvestigationPayload.goal_states()
  @stage_states ~w(pending running waiting completed failed stale skipped stopped unknown)
  @stage_keys ~w(current detail reason stage state subtasks subtasks_total url your_turn)
  @subtask_keys ~w(current detail id outcome state)
  @maximum_subtasks 6
  @maximum_section_characters 3_000
  # As long as a task offer's request can be (`Ryker.Records.RecordPayload`).
  @maximum_request_characters 12_000

  def valid?(task),
    do: optional_text?(task["request"], @maximum_request_characters) and stages?(task["stages"])

  def blocks(task), do: request(task) ++ progress(task["stages"])

  defp request(%{"request" => request, "title" => title})
       when is_binary(request) and request != title do
    lines = request |> escape() |> String.split("\n") |> Enum.flat_map(&pieces/1)
    sections(["*The request*" | lines], &section/1)
  end

  defp request(_task), do: []

  defp progress(stages) do
    ["*Progress*" | Enum.flat_map(stages, &stage_lines/1)] |> sections(&expanded_section/1)
  end

  # A line longer than one section is cut at word boundaries into lines that
  # fit, so no part of the request is lost to a section's limit.
  defp pieces(line) do
    if String.length(line) <= @maximum_section_characters - 200,
      do: [line],
      else: line |> String.split(" ") |> Enum.chunk_while("", &fit/2, &done/1)
  end

  defp fit(word, ""), do: {:cont, word}

  defp fit(word, line) do
    if String.length(line) + 1 + String.length(word) > @maximum_section_characters - 200,
      do: {:cont, line, word},
      else: {:cont, line <> " " <> word}
  end

  defp done(""), do: {:cont, ""}
  defp done(line), do: {:cont, line, ""}

  defp stage_lines(stage) do
    subtasks = Enum.map(stage["subtasks"], &subtask_line/1)

    shown = length(stage["subtasks"])
    total = stage["subtasks_total"]

    coverage =
      if is_integer(total) and total > shown,
        do: ["    Showing #{shown} of #{total} subtasks"],
        else: []

    [stage_line(stage) | reason_line(stage["reason"])] ++ subtasks ++ coverage
  end

  # Why a stage failed reads on its own line under it, not after a "·" where
  # it blended into the row (Andrew, 2026-09-28).
  defp reason_line(nil), do: []
  defp reason_line(reason), do: ["    " <> display(reason, 500)]

  defp stage_line(stage) do
    text =
      stage["stage"]
      |> label()
      |> with_detail(stage["detail"])
      |> link(stage["url"])
      |> handoff(stage["your_turn"])

    emphasize("#{glyph(stage["state"])} #{text}", stage["current"])
  end

  defp subtask_line(subtask) do
    text =
      subtask["outcome"]
      |> display(250)
      |> with_detail(subtask["detail"])

    "    " <> emphasize("#{goal_glyph(subtask["state"])} #{text}", subtask["current"])
  end

  # An exact reference such as #617 or a handoff arrow reads as part of the
  # stage name; every other value is a separate fact.
  defp with_detail(text, nil), do: text

  defp with_detail(text, detail) do
    detail = display(detail, 200)
    separator = if String.starts_with?(detail, ["#", "←"]), do: " ", else: " · "
    text <> separator <> detail
  end

  defp link(text, nil), do: text
  defp link(text, url), do: "<#{url}|#{String.replace(text, "|", "&#124;")}>"

  defp handoff(text, true), do: text <> " ← 🙋 your turn"
  defp handoff(text, _your_turn), do: text

  defp emphasize(text, true), do: "*#{text}*"
  defp emphasize(text, _current), do: text

  # Slack bounds one section; text splits on whole lines so no line, and no
  # stage row, is ever cut in half.
  defp sections(lines, block) do
    lines
    |> Enum.reduce([[]], fn line, [current | rest] ->
      if current != [] and length_of(current ++ [line]) > @maximum_section_characters,
        do: [[line], current | rest],
        else: [current ++ [line] | rest]
    end)
    |> Enum.reverse()
    |> Enum.map(&block.(Enum.join(&1, "\n")))
  end

  defp length_of(lines), do: lines |> Enum.join("\n") |> String.length()

  defp stages?(stages) when is_list(stages) do
    Enum.map(stages, & &1["stage"]) in [
      TaskStages.stages(),
      TaskStages.stages() ++ ["unassigned"]
    ] and
      Enum.all?(stages, &stage?/1)
  end

  defp stages?(_stages), do: false

  defp stage?(stage) when is_map(stage) do
    Enum.sort(Map.keys(stage)) == Enum.sort(@stage_keys) and stage["state"] in @stage_states and
      is_boolean(stage["current"]) and is_boolean(stage["your_turn"]) and
      optional_text?(stage["detail"], 200) and optional_text?(stage["reason"], 500) and
      url?(stage["url"]) and
      subtasks?(stage["subtasks"], stage["subtasks_total"])
  end

  defp stage?(_stage), do: false

  defp subtasks?(subtasks, total) when is_list(subtasks) do
    length(subtasks) <= @maximum_subtasks and Enum.all?(subtasks, &subtask?/1) and
      (is_nil(total) or (is_integer(total) and total >= length(subtasks) and total <= 1_000_000))
  end

  defp subtasks?(_subtasks, _total), do: false

  defp subtask?(subtask) when is_map(subtask) do
    Enum.sort(Map.keys(subtask)) == Enum.sort(@subtask_keys) and text?(subtask["id"], 120) and
      text?(subtask["outcome"], 250) and optional_text?(subtask["detail"], 200) and
      is_boolean(subtask["current"]) and subtask["state"] in @goal_states
  end

  defp subtask?(_subtask), do: false

  defp url?(nil), do: true

  defp url?(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        String.length(value) <= 2_048

      _invalid ->
        false
    end
  end

  defp optional_text?(nil, _maximum), do: true
  defp optional_text?(text, maximum), do: text?(text, maximum)

  defp text?(text, maximum),
    do:
      is_binary(text) and String.valid?(text) and String.length(text) in 1..maximum and
        :binary.match(text, <<0>>) == :nomatch and String.trim(text) != ""

  defp display(text, maximum), do: text |> escape() |> truncate(maximum)

  defp label("workspace_setup"), do: "Workspace setup"
  defp label("planning"), do: "Planning"
  defp label("implementation"), do: "Implementation"
  defp label("self_review"), do: "Self-review and checks"
  defp label("draft_pr"), do: "Draft PR"
  defp label("ci"), do: "CI"
  defp label("review_and_merge"), do: "Review and merge"
  defp label("unassigned"), do: "Other subtasks"

  defp glyph("completed"), do: "✓"
  defp glyph("running"), do: "▸"
  defp glyph("waiting"), do: "◷"
  defp glyph("failed"), do: "!"
  defp glyph("stale"), do: "↻"
  defp glyph("skipped"), do: "−"
  defp glyph("stopped"), do: "■"
  defp glyph("unknown"), do: "?"
  defp glyph("pending"), do: "○"

  @doc "The shared glyph for a goal state, on any card that shows a goal."
  @spec goal_glyph(String.t()) :: String.t()
  def goal_glyph("completed"), do: "✓"
  def goal_glyph("working"), do: "▸"
  def goal_glyph("waiting"), do: "◷"
  def goal_glyph("blocked"), do: "!"
  def goal_glyph(state) when state in ~w(excluded cancelled), do: "−"
  def goal_glyph("ready"), do: "○"
end
