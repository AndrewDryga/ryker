defmodule Ryker.ControlPlane.FindingsPage do
  @moduledoc false
  use Phoenix.Component

  import Ryker.ControlPlane.Components,
    only: [pager: 1, result_count: 1, timestamp: 1]

  alias Ryker.ControlPlane.{ConfigurationGuide, SlackMarkdown}

  # Saved investigation conclusions inside the shared shell: the closed help,
  # the quiet count, then the entries with their evidence links. The shell
  # renders the title and description; there is no filter here to invent.
  def render(assigns) do
    ~H"""
    <div class="findings-view" role="region" aria-label="Investigation findings">
      <ConfigurationGuide.render page={:findings} />
      <.result_count count={@view.total} one="finding" many="findings" />
      <p :if={@view.total == 0} class="empty-state">
        No findings yet. A conversation note or an alert alone is not an investigation conclusion.
      </p>
      <div class="memory-cards">
        <article :for={item <- @view.items} class="memory-card finding-card" id={"finding-#{item.id}"}>
          <header>
            <h2>{classification(item.classification)}</h2>
            <time datetime={DateTime.to_iso8601(item.at)}>{timestamp(item.at)}</time>
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
      <.pager
        page={@view.page}
        pages={@view.pages}
        path={&"/findings?page=#{&1}"}
        label="Finding pages"
      />
    </div>
    """
  end

  defp classification("unexplained"), do: "Not explained yet"
  defp classification("explained"), do: "Explained by evidence"
  defp classification("expected"), do: "Expected behavior"
  defp classification("out_of_scope"), do: "Outside this investigation"
  defp classification(_), do: "Finding recorded"
end
