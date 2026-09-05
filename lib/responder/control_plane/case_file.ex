defmodule Responder.ControlPlane.CaseFile do
  @moduledoc "The readable, server-rendered front page of an episode."
  use Phoenix.Component

  def render(assigns) do
    ~H"""
    <section class="case-file">
      <header class="case-file-heading">
        <div>
          <p class="eyebrow">Episode</p><h2>{@case_file.title}</h2>
          <p class="case-file-source">
            {@episode.destination}<span :if={@case_file.repository}> · {@case_file.repository}</span>
          </p>
        </div>
        <div class="case-file-state">
          <span>{human(@episode.state)}</span><p>{@episode.next_action}</p>
        </div>
      </header>
      <section class="case-conversation" aria-label="Conversation">
        <header>
          <h3>Conversation</h3><p>
            Latest 20 retained source messages · actual delivery status shown separately
          </p>
        </header>
        <p :if={@case_file.messages == []} class="empty">
          Source content was not retained for this episode. The execution history remains below.
        </p>
        <article
          :for={message <- @case_file.messages}
          id={"case-message-#{message.id}"}
          class="case-message"
        >
          <div class="case-message-avatar" aria-hidden="true">U</div>
          <div class="case-message-content">
            <div class="case-message-byline">
              <strong>{message.actor}</strong><span>{human(message.transport)}</span><time>{time(
                message.at
              )}</time>
            </div>
            <p :if={message.available}>{message.text}</p>
            <p :if={!message.available} class="empty">Source content not recorded or expired</p>
            <a href={message.href}>Inspect admission request →</a>
          </div>
        </article>
        <article :if={@case_file.reply} class="case-message case-message-answer">
          <div class="case-message-avatar" aria-hidden="true">R</div>
          <div class="case-message-content">
            <div class="case-message-byline">
              <strong>Responder</strong><span>{@case_file.reply_status}</span>
            </div><p>{@case_file.reply}</p>
          </div>
        </article>
        <p :if={!@case_file.reply} class="case-no-answer">
          No visible answer recorded yet. {@episode.next_action}
        </p>
      </section>
      <details class="case-technical" id="case-technical">
        <summary>Identity and timestamps</summary>
        <dl>
          <dt>Episode</dt><dd><code>{@episode.ref}</code></dd><dt>Created</dt><dd>
            {time(@episode.created_at)}
          </dd><dt>Latest change</dt><dd>{time(@episode.updated_at)}</dd>
        </dl>
      </details>
    </section>
    """
  end

  defp human(value), do: value |> to_string() |> String.replace("_", " ") |> String.capitalize()
  defp time(%DateTime{} = value), do: Calendar.strftime(value, "%d %b · %H:%M:%S UTC")
  defp time(_), do: "Not recorded"
end
