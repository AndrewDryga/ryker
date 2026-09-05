defmodule Responder.ControlPlane.AuditHTML do
  alias Responder.ControlPlane.SlackMarkdown
  alias Responder.ControlPlane.SlackNames

  @moduledoc "Human-readable actions, with immutable identities kept available as secondary detail."
  alias Responder.ControlPlane.Components

  @events %{
    "input_admitted" =>
      {"Message accepted", "The message was attached to a request for processing."},
    "owner_transferred" =>
      {"Processing handed over", "The next worker took responsibility for this request."},
    "input_wait_started" => {"Asked for your input", "Work paused until someone replies."},
    "event_wait_started" =>
      {"Waiting for a result", "Work paused until the expected external event arrives."},
    "wait_resumed" => {"Work resumed", "The expected input or event arrived."},
    "result_accepted" =>
      {"Answer accepted", "Responder validated the result and saved the next action."},
    "delivery_confirmed" =>
      {"Reply delivered", "The destination confirmed the saved reply or platform action."},
    "episode_cancelled" => {"Request stopped", "No further work is scheduled for this request."},
    "reaction_recorded" => {"Reaction saved", "A reaction was recorded for the source message."},
    "denied" =>
      {"Slack action denied",
       "The interaction did not have permission to run. No task action was authorized."},
    "invalid" =>
      {"Slack action rejected",
       "The interaction was invalid or stale. No task action was authorized."}
  }

  def render(rows) do
    [
      "<section class=\"audit-feed\"><p class=\"page-explanation\">Who changed what, and what happened next. The latest 100 saved events, newest first.</p>",
      if(rows == [],
        do: "<p class=\"empty\">No actions recorded yet.</p>",
        else: Enum.map(rows, &row/1)
      ),
      "</section>"
    ]
  end

  defp row(row) do
    kind = to_string(row.kind)

    {title, explanation} =
      Map.get(
        @events,
        kind,
        {human(kind),
         "An operator action was recorded. Inspect its saved record for the exact target."}
      )

    [
      "<article class=\"audit-event\"><time>",
      escape(Components.timestamp(row.updated_at)),
      "</time><div><h3>",
      escape(title),
      "</h3><p>",
      escape(explanation),
      "</p><div class=\"audit-byline\">",
      "<span title=\"",
      escape(Map.get(row, :actor)),
      "\">",
      escape(actor(row)),
      "</span>",
      if(row[:href],
        do: ["<a href=\"", escape(row.href), "\">", request_label(row), "</a>"],
        else: []
      ),
      "</div><details><summary>Technical record</summary><dl><dt>Record</dt><dd>",
      escape(row.ref),
      "</dd><dt>Action</dt><dd>",
      escape(kind),
      "</dd><dt>Target</dt><dd>",
      escape(row[:target] || row.ref),
      "</dd><dt>Saved detail</dt><dd>",
      escape(row.summary),
      "</dd></dl></details></div></article>"
    ]
  end

  defp actor(%{source: :slack, workspace: workspace, actor: actor}),
    do: SlackNames.name(workspace, actor)

  defp actor(%{actor: "local-operator"}), do: "You · console"
  defp actor(row), do: Map.get(row, :actor) || "Actor not recorded"

  defp request_label(row) do
    title = row[:request_title] || "Open request →"

    case SlackNames.workspace_from_destination(row[:request_conversation]) do
      nil -> escape(title)
      workspace -> SlackMarkdown.mentions(title, workspace)
    end
  end

  defp human(value), do: value |> String.replace(["_", ":"], " ") |> String.capitalize()
  defp escape(nil), do: "Not recorded"

  defp escape(value),
    do: value |> to_string() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
