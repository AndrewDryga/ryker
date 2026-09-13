defmodule Responder.ControlPlane.LabPage do
  @moduledoc "Direct conversations with the agent, through the normal durable action boundary."
  use Phoenix.Component
  import Responder.ControlPlane.Components
  alias Responder.ControlPlane.HTML

  def render(assigns) do
    ~H"""
    <div class={"conversation-lab #{if @snapshot, do: "has-conversation", else: "lab-welcome"}"}>
      <aside class="lab-directory">
        <div class="lab-directory-heading">
          <h1>Conversations</h1>
        </div>
        <a :if={@snapshot} class="ui-button secondary" href="/conversations/new"><.icon name={:plus} />New conversation</a>
        <div class="lab-directory-list">
          <p class="ui-eyebrow">RECENT CONVERSATIONS</p><p
            :if={@items == []}
            class="lab-directory-empty"
          >
            Your conversations will appear here after you send a message.
          </p>
          <.link
            :for={item <- @items}
            navigate={"/conversations/#{item.id}"}
            aria-current={if @snapshot && item.id == @snapshot.conversation_id, do: "page"}
          ><strong>{Map.get(item, :title, "Conversation")}</strong><span>{item.message_count} inputs · {timestamp(
            item.updated_at
          )}</span></.link>
        </div>
      </aside>
      <div :if={!@snapshot} class="lab-start">
        <h2>Start a conversation</h2><p>
          Direct conversations with Responder, without Slack. Every message runs through the configured models and tools, and each reply links its execution timeline.
        </p><a class="ui-button primary" href="/conversations/new">New conversation
        <.icon name={:arrow} /></a><p class="lab-start-notes">
          <strong>Real tools, local replies.</strong>
          Slack effects are emulated here. Repository and Emisar actions still use their configured authority.
          <a href="/configuration">Inspect configuration</a>
        </p>
      </div>
      <section :if={@snapshot} class="lab-chat" aria-label="Conversation">
        <div class="lab-chat-header">
          <div>
            <span class="ui-eyebrow">CONVERSATION</span><h2>{conversation_title(@snapshot)}</h2>
          </div><span class={"ui-status status-#{if @snapshot.blocked, do: "attention", else: "quiet"}"}><i></i>{cond do
            @snapshot.blocked -> "Needs attention"
            @snapshot.live -> "Processing"
            @snapshot.messages == [] -> "Ready for your message"
            true -> "Conversation saved"
          end}</span>
        </div>
        <div :if={@snapshot.messages == []} class="lab-first-message">
          <h3>
            Send a message
          </h3><p>
            Ask a question, investigate an issue, or try a feature. Your first message starts the conversation.
          </p>
        </div>
        <p id="lab-announcement" class="sr-only" role="status" aria-live="polite" aria-atomic="true">
          {@announcement}
        </p>
        <div
          id="lab-messages"
          phx-update="stream"
          class="lab-transcript"
          role="log"
          aria-live="off"
          aria-label="Conversation messages"
        >
          <article
            :for={{id, message} <- @messages}
            id={id}
            class={"lab-chat-message actor-#{message.actor}"}
          >
            <span class="story-avatar" aria-hidden="true">{if message.actor == :operator,
              do: "You",
              else: "r."}</span><div class="lab-chat-message-content">
              <div class="story-byline">
                <strong>{actor(message.actor)}</strong><time>{timestamp(message.occurred_at)}</time><span>{message_status(
                  message
                )}</span>
              </div><div class="chat-message-text markdown-preview">
                {Phoenix.HTML.raw(Responder.ControlPlane.SlackMarkdown.preview(message.text || ""))}
              </div><div class="chat-message-extras">
                {Phoenix.HTML.raw(HTML.lab_message_extras(message))}
              </div><details
                :if={message.record_refs != [] || message.artifact_refs != []}
                class="document-provenance"
              >
                <summary>Linked record identities</summary><p :for={
                  ref <- message.record_refs ++ message.artifact_refs
                }>
                  {ref}
                </p>
              </details>
            </div>
          </article>
        </div>
        <form
          id={"lab-composer-#{@snapshot.conversation_id}"}
          phx-update="ignore"
          class="composer lab-native-composer"
          method="post"
          enctype="multipart/form-data"
          action={"/conversations/#{@snapshot.conversation_id}/messages"}
        >
          <input type="hidden" name="_token" value={@token} /><label class="sr-only" for="lab-message">Message Responder</label><textarea
            id="lab-message"
            name="message"
            maxlength="20000"
            data-max-bytes="20000"
            rows="4"
            placeholder="Message Responder…"
          ></textarea>
          <div class="native-composer-bottom">
            <div>
              <label for="lab-attachments">Attach files</label><input
                id="lab-attachments"
                name="attachments[]"
                type="file"
                multiple
                accept="image/png,image/jpeg,image/webp,image/gif,text/plain,text/markdown,text/csv,application/json,application/yaml,application/x-yaml,application/pdf"
              /><small>Up to 2 files · 8 MiB total</small>
            </div><button class="ui-button primary" type="submit">Send message <.icon name={:arrow} /></button>
          </div><p class="composer-status" role="status" hidden></p>
        </form><p class="lab-chat-footer">
          Saved on acceptance · ⌘ / Ctrl + Enter to send · Latest 200 visible messages
        </p>
      </section>
      <aside :if={@snapshot} class="lab-runtime" aria-label="Processing progress">
        <div class="rail-heading">
          <h2>Behind this conversation</h2><.icon name={:activity} />
        </div><a href={
          Responder.ControlPlane.Activity.conversation_path(
            "control_plane",
            "control-plane:lab:#{@snapshot.conversation_id}"
          )
        }>All requests in this conversation →</a>
        <div :if={@snapshot.messages == []} class="lab-runtime-empty">
          <.icon name={:clock} /><strong>No request yet</strong><p>
            When you send a message, its admission and execution progress will appear here.
          </p>
        </div>
        <article
          :for={progress <- Map.get(@snapshot, :admission_progress, [])}
          id={"lab-progress-#{progress.id}"}
          class="native-admission-progress"
        >
          <p class="ui-eyebrow">ADMISSION</p><strong>{progress.phase}</strong><p>{progress.title}</p><span>{Float.round(
            progress.elapsed_ms / 1000,
            1
          )}s since received</span><small :if={progress.target}>{progress.target}</small><.link navigate={
            progress.href
          }>Inspect request <.icon name={:arrow} /></.link><details>
            <summary>Execution history</summary><p>
              Generation {progress.generation} · {progress.claims} claims
            </p><p>Last observed {timestamp(progress.observed_at)}</p>
          </details>
        </article>
        <.link
          :for={{episode, index} <- Enum.with_index(@snapshot.episodes, 1)}
          navigate={"/timeline/#{URI.encode_www_form(episode.ref)}"}
          class="lab-episode-link"
        ><span class="ui-eyebrow">EPISODE {index}</span><strong>{label(episode.state)}</strong><p>
          {episode.next_action}
        </p><span>Conversation, timeline & model requests <.icon name={:arrow} /></span></.link>
        <details class="lab-runtime-identity">
          <summary>Conversation identity</summary><code>{@snapshot.conversation_id}</code>
        </details>
      </aside>
    </div>
    """
  end

  def announcement(nil, _current), do: ""

  def announcement(previous, current) do
    known = MapSet.new(previous.messages, & &1.ref)

    replies =
      Enum.count(
        current.messages,
        &(&1.actor == :responder and not MapSet.member?(known, &1.ref))
      )

    phases = Enum.map(Map.get(current, :admission_progress, []), & &1.phase)
    changed = phases != Enum.map(Map.get(previous, :admission_progress, []), & &1.phase)

    notices =
      [
        if(replies > 0,
          do: "#{replies} new #{if replies == 1, do: "reply", else: "replies"} from Responder."
        ),
        if(changed, do: List.first(phases))
      ]
      |> Enum.reject(&is_nil/1)

    if notices == [], do: nil, else: Enum.join(notices, " ")
  end

  defp message_status(%{actor: :operator, status: status}) when status in [:decided, :pending],
    do: "Sent"

  defp message_status(%{actor: :responder, status: :settled}), do: "Delivered"
  defp message_status(message), do: label(message.status)

  defp actor(:operator), do: "You"
  defp actor(:integration), do: "Integration"
  defp actor(_), do: "Responder"

  defp conversation_title(snapshot) do
    case Enum.find(snapshot.messages, &(&1.actor == :operator)) do
      nil -> "New conversation"
      message -> String.slice(message.text, 0, 100)
    end
  end
end
