defmodule Ryker.ControlPlane.ConfigurationGuide do
  @moduledoc false
  use Phoenix.Component

  import Ryker.ControlPlane.Components, only: [page_help: 1]

  attr(:page, :atom, required: true)

  def render(assigns) do
    assigns =
      assign(assigns,
        id: id(assigns.page),
        label: label(assigns.page),
        paragraphs: paragraphs(assigns.page)
      )

    ~H"""
    <.page_help id={@id} label={@label} class="configuration-help">
      <p :for={paragraph <- @paragraphs}>{paragraph}</p>
    </.page_help>
    """
  end

  def description(:rules),
    do:
      "Standing rules let Ryker watch for specific events and use your instructions to decide what to do when one happens."

  def description(:schedules),
    do: "Schedules let Ryker run a task once at a future time or repeat it on a regular schedule."

  def description(:subscriptions),
    do: "Waits are work Ryker has paused until a timer fires or a specific update arrives."

  def description(:memory),
    do:
      "Memory shows what Ryker learned from conversations and the reusable facts people explicitly asked it to remember."

  def description(:preferences),
    do:
      "Preferences are saved choices about Ryker’s response detail, health-check depth, and reply location."

  def description(:guidance),
    do:
      "Guidance gives Ryker advice and checklists to use in the conversations and repositories where they apply."

  def description(:instructions),
    do:
      "Every time Ryker decides, works, or learns, it receives the global instructions and any instructions saved for the current Slack channel."

  def description(:findings),
    do:
      "Findings are conclusions Ryker saves from investigations, together with the evidence behind them."

  defp label(:rules), do: "How to create a standing rule"
  defp label(:schedules), do: "How to create a schedule"
  defp label(:subscriptions), do: "How waits work"
  defp label(:memory), do: "How memory works"
  defp label(:preferences), do: "How to save a preference"
  defp label(:guidance), do: "How to add guidance"
  defp label(:instructions), do: "How instructions work"
  defp label(:findings), do: "How findings work"

  defp id(:subscriptions), do: "waits-help"
  defp id(page), do: "#{page}-help"

  defp paragraphs(:rules) do
    [
      "In the Slack channel where the rule should apply, tell Ryker what event to watch for, any conditions that must match, and how it should respond.",
      "For example: “When someone posts a Terraform plan in this channel, review it for risky changes.”",
      "Ryker shows the exact rule for confirmation before saving it. Later, ask Ryker to update, pause, resume, or delete it—or manage it here."
    ]
  end

  defp paragraphs(:schedules) do
    [
      "In the Slack conversation where the results should appear, tell Ryker what to do and when. Include the time zone and whether the task should run once or repeat.",
      "For example: “Every weekday at 09:00 Berlin time, summarize unresolved incidents in this channel.”",
      "Ryker shows the schedule for confirmation before saving it. Later, ask Ryker to update, pause, resume, or delete it—or manage it here. Run now starts an extra occurrence without changing the saved schedule."
    ]
  end

  defp paragraphs(:subscriptions) do
    [
      "Ryker creates a wait when active work cannot continue yet. You can also tell it to continue at a particular time or after a particular event.",
      "For example: “Continue when this pull request is merged” or “Check again tomorrow morning.”",
      "Each wait shows what can resume the work. This page is read-only: waits resume the original work when their condition is met, or end when their deadline is reached."
    ]
  end

  defp paragraphs(:memory) do
    [
      "Ryker learns useful decisions, explanations, intentions, and changes from conversations, even when it does not reply. Related updates become current knowledge that can help with later work.",
      "For a specific reusable fact, ask Ryker to remember it and confirm the proposal it shows you.",
      "To correct learned knowledge, explain the change in its source conversation. You can ask Ryker to forget a confirmed fact or remove it here. Memory provides context; it does not grant permission or prove that something is still true."
    ]
  end

  defp paragraphs(:preferences) do
    [
      "Tell Ryker what you prefer and where it should apply: to you, this conversation, a repository, or the workspace.",
      "For example: “Keep replies concise for me” or “Use deep health checks in this repository.” Reply-location preferences cannot be limited to a repository.",
      "Ryker shows the normalized preference for confirmation before saving it. Use this page to pause, resume, or delete it."
    ]
  end

  defp paragraphs(:guidance) do
    [
      "Ask Ryker to save an instruction, checklist, or working convention. Include where it should apply and, when useful, how long it should be retained.",
      "For example: “When reviewing this repository, always check that database migrations can be rolled back.”",
      "Ryker shows the guidance for confirmation before saving it. To replace it, continue its source conversation and explain what should change. You can pause, resume, or delete it here."
    ]
  end

  defp paragraphs(:instructions) do
    [
      "Use global instructions for stable defaults that should apply everywhere. Add channel instructions from a channel’s page when something should apply only there.",
      "Both sets of instructions are sent to Ryker. If they give different guidance about the same behavior, Ryker treats the channel instruction as more specific for work in that channel.",
      "Instructions can shape choices such as style and level of detail. They cannot change permissions, available tools, confirmation requirements, or other fixed system rules. Changes apply to the next model turn."
    ]
  end

  defp paragraphs(:findings) do
    [
      "During a substantive investigation, Ryker saves useful conclusions automatically—what caused a problem, why behavior is expected, or what important question remains unanswered.",
      "Routine lookups, raw alerts, and unchanged repeated conclusions are not saved as findings.",
      "Findings make investigations easier to review and become part of the completed cases Ryker can recall when similar work appears later. Open a finding to inspect its evidence or continue the source investigation if its conclusion is incomplete or wrong."
    ]
  end
end
