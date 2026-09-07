defmodule Responder.ControlPlane.FindingsPage do
  @moduledoc false
  use Phoenix.Component
  alias Responder.ControlPlane.SlackMarkdown

  def render(assigns) do
    ~H"""
    <div class="findings-view" role="region" aria-label="Investigation findings">
      <div class="page-help">
        <h2>What was found</h2>
        <p>Findings are saved conclusions: what needs explaining, what evidence explains it,
          or why the behavior is expected. This is not a second list of episodes.</p>
        <p>
          Ask Responder to investigate in a conversation or <a href="/lab">Conversation Lab</a>.
          It can save a finding with the evidence it collected. Saving a finding does not create
          an incident or send a message. To correct or extend a conclusion, follow up in the source conversation
          using <em>Open investigation</em> below; the original finding remains part of the history.
        </p>
      </div>
      <p class="findings-count">
        {@view.total} {if @view.total == 1, do: "finding", else: "findings"}
      </p>
      <p :if={@view.total == 0} class="empty-state">
        No findings yet. A conversation note or an alert alone is not an investigation conclusion.
      </p>
      <div class="memory-cards">
        <article :for={item <- @view.items} class="memory-card finding-card" id={"finding-#{item.id}"}>
          <header>
            <h2>{classification(item.classification)}</h2>
            <time datetime={DateTime.to_iso8601(item.at)}>{Calendar.strftime(
              item.at,
              "%d %b, %H:%M UTC"
            )}</time>
          </header>
          <div class="markdown-preview finding-conclusion">
            {Phoenix.HTML.raw(SlackMarkdown.preview(item.what))}
          </div>
          <div :if={item.reason} class="finding-reason">
            <h3>Why</h3><div class="markdown-preview">
              {Phoenix.HTML.raw(SlackMarkdown.preview(item.reason))}
            </div>
          </div>
          <p :if={item.scope} class="memory-source">Scope: {item.scope}</p>
          <section :if={item.evidence != []} class="finding-evidence">
            <h3>Supporting evidence</h3>
            <div :for={evidence <- item.evidence}>
              <div class="markdown-preview">
                {Phoenix.HTML.raw(SlackMarkdown.preview(evidence.text))}
              </div>
              <a :if={evidence.path} href={evidence.path}>{evidence.label} →</a>
            </div>
          </section>
          <footer><a href={item.path}>Open investigation →</a></footer>
        </article>
      </div>
      <nav :if={@view.pages > 1} class="pagination" aria-label="Finding pages">
        <a :if={@view.page > 1} href={"/findings?page=#{@view.page - 1}"}>← Previous</a>
        <span>Page {@view.page} of {@view.pages}</span>
        <a :if={@view.page < @view.pages} href={"/findings?page=#{@view.page + 1}"}>Next →</a>
      </nav>
    </div>
    """
  end

  defp classification("unexplained"), do: "Not explained yet"
  defp classification("explained"), do: "Explained by evidence"
  defp classification("expected"), do: "Expected behavior"
  defp classification("out_of_scope"), do: "Outside this investigation"
  defp classification(_), do: "Finding recorded"
end
