defmodule Responder.ControlPlane.WorkflowGuide do
  @moduledoc "Discoverable entry points into existing product workflows."
  use Phoenix.Component
  alias Responder.ControlPlane.CardLab

  @workflows [
    {"Engineering tasks",
     "Ask for a code change. Review the task offer, follow live progress and subtasks, inspect the changes on the web, then review the draft pull request.",
     [{"Repositories", "/repositories"}, {"Working copies", "/workspaces"}],
     ~w(task-offer task-card publication)},
    {"Investigations",
     "Ask Responder to investigate an incident. Follow its evidence, findings, open questions, and resolution in one timeline.",
     [{"Incident rooms", "/incident-rooms"}, {"Findings", "/findings"}],
     ~w(incident-room investigation-record)},
    {"Standing rules",
     "Ask it to watch a channel for matching events and carry out a read-only instruction. Confirm the rule before it starts listening.",
     [{"Manage rules", "/rules"}], ~w(behavior-offer)},
    {"Scheduled work",
     "Ask for a one-off or recurring task with a timezone. Review the schedule before enabling it; pause, change, or run it now from its page.",
     [{"Schedules", "/schedules"}], ~w(schedule-offer automation-change)},
    {"Preferences & guidance",
     "Save response preferences or a review checklist for a person, conversation, repository, or workspace. Confirm the scope on the proposed card.",
     [{"Preferences", "/preferences"}, {"Guidance", "/guidance"}], []},
    {"Memory & continuity",
     "Save an alias, repository binding, evidence route, or relationship. Review stale and duplicate memories; inspect recalled conversation summaries on channel pages and model inputs.",
     [{"Memory & reviews", "/memory"}, {"Channels", "/channels"}], ~w(memory-offer)},
    {"Questions & event waits",
     "Answer a clarification in the original conversation, or ask Responder to wait for an external event and continue when it arrives.",
     [{"Waits", "/subscriptions"}, {"Activity", "/"}], ~w(wait-record)},
    {"Governed operations",
     "Review the specific operation and approve it in Emisar when required. Follow approval and execution progress from the request timeline.",
     [{"Connections & grants", "/configuration"}], ~w(governed-action)},
    {"Slack conversations",
     "Set up a channel, continue a running conversation, or confirm an extra post to another destination. Check message and pending-response states in Card Lab.",
     [{"Channels", "/channels"}],
     ~w(channel-welcome channel-setup channel-settings slack-post message thread-status)},
    {"Slack App Home",
     "Open Responder’s Home tab in Slack to manage your saved preferences, guidance, and memory reviews.",
     [{"Memory & reviews", "/memory"}], ~w(app-home app-home-modal)}
  ]

  def entries do
    catalog = CardLab.catalog()

    Enum.map(@workflows, fn {title, description, links, families} ->
      previews =
        Enum.map(families, fn id ->
          family = Enum.find(catalog, &(&1.id == id))
          %{label: family.title, href: "/card-lab/#{id}/#{hd(family.states).id}"}
        end)

      %{title: title, description: description, links: links, previews: previews}
    end)
  end

  def render(assigns) do
    assigns = assign(assigns, :entries, entries())

    ~H"""
    <section id="workflows" class="workflow-guide">
      <h2>What you can do</h2>
      <div class="workflow-list">
        <article :for={entry <- @entries}>
          <h3>{entry.title}</h3><div>
            <p>{entry.description}</p>
            <nav aria-label={entry.title}>
              <a :for={{label, href} <- entry.links} href={href}>{label} →</a>
            </nav>
            <details :if={entry.previews != []} id={"workflow-#{URI.encode_www_form(entry.title)}"}>
              <summary>Card previews</summary><nav aria-label={entry.title <> " previews"}>
                <a :for={preview <- entry.previews} href={preview.href}>{preview.label} →</a>
              </nav>
            </details>
          </div>
        </article>
      </div>
    </section>
    """
  end
end
