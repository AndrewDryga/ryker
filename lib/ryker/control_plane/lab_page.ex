defmodule Ryker.ControlPlane.LabPage do
  @moduledoc """
  Direct conversations with the agent, through the normal durable action boundary.

  Two regions: a readable directory of retained conversations and the
  conversation itself. The index is an empty draft bound to a fresh identity,
  so nothing is written until the first message; an open conversation is the
  same view with its retained transcript. The composer sits at the bottom of
  the column in both, and the draft lists the examples above it. Each message
  links only its own retained execution.
  """
  use Phoenix.Component
  import Ryker.ControlPlane.Components
  alias Ryker.ControlPlane.HTML

  # Authored UI examples approved on 2026-09-09, grouped on 2026-09-19 by what
  # Ryker does. They are hints for what an operator could write, not claims
  # about configured access, and one of them is the placeholder of a newly
  # opened draft or conversation.
  @example_groups [
    {"Investigate", :search,
     [
       "Investigate why this service keeps restarting.",
       "Summarize the attached log and identify likely causes.",
       "Ask me three questions to clarify this investigation."
     ]},
    {"Build", :code,
     [
       "Review this change for bugs and missing tests.",
       "Help me turn this issue into an engineering task.",
       "Compare these two approaches and explain the trade-offs.",
       "Generate a small illustration of a rocket launch."
     ]},
    {"Remember", :bell,
     [
       "Remind me tomorrow at 9:00 to check the deployment.",
       "Remember that I prefer concise incident updates.",
       "Show the automations active in this conversation."
     ]}
  ]

  @examples Enum.flat_map(@example_groups, &elem(&1, 2))

  def examples, do: @examples

  def random_example, do: Enum.random(@examples)

  @doc """
  The example an open conversation shows, fixed by its identity.

  The composer is a `phx-update="ignore"` form, so the browser keeps whatever
  the first render carried across patches and reconnects. Deriving the pick
  from the conversation id makes the server agree with that on every render.
  """
  def example_for(conversation_id) when is_binary(conversation_id),
    do: Enum.at(@examples, :erlang.phash2(conversation_id, length(@examples)))

  def render(assigns) do
    assigns =
      assigns
      |> assign(:example_groups, @example_groups)
      |> assign(:groups, directory_groups(assigns.items, assigns.now))
      |> assign(:progress, progress_by_input(assigns.snapshot))
      |> assign_new(:readiness, fn ->
        %{
          chat: %{
            state: :ready,
            title: "Chat is ready",
            detail: "Messages can be accepted and processed."
          }
        }
      end)
      |> then(&assign(&1, :chat_ready, get_in(&1, [:readiness, :chat, :state]) == :ready))
      |> assign(
        :selected,
        if(assigns.snapshot[:draft], do: nil, else: assigns.snapshot.conversation_id)
      )

    ~H"""
    <div class="conversation-lab" id="conversation-lab">
      <aside class="lab-directory" id="lab-directory" aria-label="Conversations">
        <div class="lab-directory-heading">
          <h1>Conversations</h1>
          <.link
            navigate="/conversations"
            class="ui-button secondary lab-new"
            aria-current={if @snapshot[:draft], do: "page"}
          ><.icon name={:plus} />New</.link>
          <button
            type="button"
            class="lab-directory-close"
            aria-label="Close conversations"
            data-lab-directory-close
          >
            <span aria-hidden="true">×</span>
          </button>
        </div>
        <div class="lab-directory-list">
          <div :if={@items == []} class="lab-directory-empty">
            <strong>No conversations yet</strong>
            <p>Send a message and it will appear here.</p>
          </div>
          <section :for={{group, items} <- @groups} class="lab-directory-group">
            <h2>{group}</h2>
            <.link
              :for={item <- items}
              navigate={"/conversations/#{item.id}"}
              class="lab-directory-item"
              title={item.title}
              aria-current={if item.id == @selected, do: "page"}
            ><span class="lab-directory-title">{item.title}</span><time datetime={
              DateTime.to_iso8601(item.updated_at)
            }>{directory_time(item.updated_at, @now)}</time></.link>
          </section>
        </div>
      </aside>
      <section class="lab-chat" aria-label="Conversation">
        <div class="lab-chat-toolbar">
          <button
            type="button"
            class="lab-directory-toggle"
            aria-controls="lab-directory"
            aria-expanded="false"
            data-lab-directory-toggle
          >
            <.icon name={:chat} />Conversations
          </button>
        </div>
        <p id="lab-announcement" class="sr-only" role="status" aria-live="polite" aria-atomic="true">
          {@announcement}
        </p>
        <div class="lab-column">
          <div
            id="lab-history"
            phx-hook="ConversationHistory"
            data-conversation={@snapshot.conversation_id}
            data-before={@history.before}
            data-history-state={history_state(@history)}
          >
            <div id="lab-history-edge" class="lab-history-edge" tabindex="-1">
              <button
                :if={history_state(@history) == "more"}
                type="button"
                class="lab-load-earlier"
                phx-click="load-older"
                phx-value-conversation={@snapshot.conversation_id}
                phx-value-before={@history.before}
              >
                Load earlier messages
              </button>
              <span class="lab-history-loading">Loading earlier messages…</span>
              <p :if={history_state(@history) == "failed"} class="lab-history-failed" role="status">
                Earlier messages could not be loaded.
                <button
                  type="button"
                  phx-click="load-older"
                  phx-value-conversation={@snapshot.conversation_id}
                  phx-value-before={@history.before}
                >
                  Try again
                </button>
              </p>
            </div>
            <div
              id="lab-messages"
              phx-update="stream"
              class="lab-transcript"
              role="log"
              aria-live="off"
              aria-label="Conversation messages"
            >
              <.chat_message
                :for={{id, message} <- @messages}
                id={id}
                message={message}
                now={@now}
                progress={@progress}
              />
            </div>
            <div id="lab-history-latest" phx-update="ignore">
              <button type="button" class="lab-new-messages" hidden>New messages</button>
            </div>
          </div>
          <section
            :if={@snapshot[:draft]}
            id="lab-examples"
            class="lab-examples"
            aria-label="Examples"
          >
            <div class="lab-example-groups">
              <div :for={{title, icon, examples} <- @example_groups} class="lab-example-group">
                <h2><span class="lab-example-badge"><.icon name={icon} /></span>{title}</h2>
                <ul>
                  <li :for={example <- examples}>
                    <button type="button" class="lab-example" data-example={example}>{example}</button>
                  </li>
                </ul>
              </div>
            </div>
          </section>
          <div id="lab-notices" class="lab-notices" phx-update="ignore" aria-live="polite"></div>
          <div class="lab-composer-dock">
            <section :if={!@chat_ready} class="lab-readiness" role="status">
              <strong>{@readiness.chat.title}</strong>
              <p>{@readiness.chat.detail}</p>
            </section>
            <form
              :if={@chat_ready}
              id={"lab-composer-#{if @snapshot[:draft], do: "new", else: @snapshot.conversation_id}"}
              phx-update="ignore"
              class="composer lab-native-composer"
              method="post"
              enctype="multipart/form-data"
              action={"/conversations/#{@snapshot.conversation_id}/messages"}
              data-draft-action={if @snapshot[:draft], do: "new"}
            >
              <input type="hidden" name="_token" value={@token} /><label
                class="sr-only"
                for="lab-message"
              >Message Ryker</label><textarea
                id="lab-message"
                name="message"
                maxlength="20000"
                data-max-bytes="20000"
                rows="3"
                placeholder={@placeholder}
              ></textarea>
              <div class="native-composer-bottom">
                <label class="lab-attach" for="lab-attachments">Attach files</label><input
                  id="lab-attachments"
                  name="attachments[]"
                  type="file"
                  multiple
                  accept="image/png,image/jpeg,image/webp,image/gif,text/plain,text/markdown,text/csv,application/json,application/yaml,application/x-yaml,application/pdf"
                  aria-describedby="lab-attachments-error"
                /><button class="ui-button primary" type="submit">
                  Send
                </button>
              </div><.form_feedback
                id="lab-attachments-error"
                message=""
                tone={:error}
                hidden={true}
                class="composer-error"
              /><.form_feedback
                message=""
                tone={:info}
                hidden={true}
                class="composer-status"
              />
            </form>
            <p :if={@chat_ready} class="lab-chat-footer">⌘ / Ctrl + Enter to send</p>
          </div>
        </div>
      </section>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:message, :map, required: true)
  attr(:now, :any, required: true)
  attr(:progress, :map, required: true)

  defp chat_message(assigns) do
    rows = Map.get(assigns.progress, assigns.message[:native_input_id], [])

    assigns =
      assigns
      |> assign(:link, inspection_link(assigns.message))
      |> assign(:state, message_state(assigns.message))
      |> assign(:failure, message_failure(assigns.message))
      |> assign(:rows, rows)
      |> assign(:typing, rows == [] and message_working?(assigns.message))

    ~H"""
    <article id={@id} class={"lab-chat-message actor-#{@message.actor}"}>
      <div class="lab-message-byline">
        <strong>{actor(@message.actor)}</strong><time datetime={
          DateTime.to_iso8601(@message.occurred_at)
        }>{directory_time(
          @message.occurred_at,
          @now
        )}</time><span :if={@state} class="lab-message-state">{@state}</span><a
          :if={@link}
          href={@link.href}
          target="_blank"
          rel="noopener"
          class="lab-message-inspect"
        >{@link.label}
        <span aria-hidden="true">↗</span><span class="sr-only"> (opens in a new tab)</span></a>
      </div>
      <div class="chat-message-text markdown-preview">
        {Phoenix.HTML.raw(Ryker.ControlPlane.SlackMarkdown.preview(@message.text || ""))}
      </div>
      {Phoenix.HTML.raw(HTML.lab_message_editor(@message))}
      <div class="chat-message-extras">{Phoenix.HTML.raw(HTML.lab_message_extras(@message))}</div>
      {Phoenix.HTML.raw(HTML.lab_message_reactions(@message))}
      {Phoenix.HTML.raw(HTML.lab_message_actions(@message))}
      <p :if={@failure} class="lab-message-failure" role="status">
        <span>{@failure.label}</span> <a href={@failure.retry}>Retry</a>
        <.link navigate={@failure.inspect}>Inspect cause</.link>
      </p>
      <p :for={row <- @rows} id={"lab-progress-#{row.id}"} class="lab-message-progress" role="status">
        <span class="lab-progress-status">{row.phase}</span><span
          id={"lab-progress-elapsed-#{row.id}"}
          class="lab-progress-elapsed"
          phx-hook="ElapsedTime"
          data-elapsed-ms={row.elapsed_ms}
          aria-hidden="true"
        >{elapsed(row.elapsed_ms)}</span><.link
          :if={row.id != @message[:input_id]}
          navigate={row.href}
        >Inspect this revision</.link>
      </p>
      <div :if={@typing} class="lab-typing-indicator" role="status" aria-label="Ryker is working">
        <span class="lab-typing-dots" aria-hidden="true"><i></i><i></i><i></i></span>
        <span>Working</span>
      </div>
    </article>
    """
  end

  # What the top edge of the transcript offers: more retained history to load,
  # a failed load to retry, or nothing once the first message is loaded. A
  # failure is never shown as the start of the conversation.
  defp history_state(%{failed: true}), do: "failed"
  defp history_state(%{exhausted: true}), do: "exhausted"
  defp history_state(_history), do: "more"

  defp elapsed(milliseconds) when milliseconds < 1_000, do: "now"

  defp elapsed(milliseconds) when milliseconds < 60_000,
    do: "#{div(milliseconds, 1_000)}s"

  defp elapsed(milliseconds) do
    seconds = div(milliseconds, 1_000)
    minutes = div(seconds, 60)
    remainder = rem(seconds, 60)
    if remainder == 0, do: "#{minutes}m", else: "#{minutes}m #{remainder}s"
  end

  def announcement(nil, _current), do: ""

  def announcement(previous, current) do
    known = MapSet.new(previous.messages, & &1.ref)

    replies =
      Enum.count(
        current.messages,
        &(&1.actor == :ryker and not MapSet.member?(known, &1.ref))
      )

    phases = Enum.map(Map.get(current, :admission_progress, []), & &1.phase)
    changed = phases != Enum.map(Map.get(previous, :admission_progress, []), & &1.phase)

    notices =
      [
        if(replies > 0,
          do: "#{replies} new #{if replies == 1, do: "reply", else: "replies"} from Ryker."
        ),
        if(changed, do: List.first(phases))
      ]
      |> Enum.reject(&is_nil/1)

    if notices == [], do: nil, else: Enum.join(notices, " ")
  end

  @doc """
  Retained conversations grouped by when they last changed, newest first.

  Labels come from the observed UTC clock; nothing here invents a summary or
  a count. Items keep the projection's order inside their group.
  """
  def directory_groups(items, now) do
    today = DateTime.to_date(now)
    yesterday = Date.add(today, -1)

    grouped =
      Enum.group_by(items, fn item ->
        case DateTime.to_date(item.updated_at) do
          ^today -> "Today"
          ^yesterday -> "Yesterday"
          _earlier -> "Earlier"
        end
      end)

    Enum.flat_map(["Today", "Yesterday", "Earlier"], fn label ->
      case grouped[label] do
        nil -> []
        group -> [{label, group}]
      end
    end)
  end

  @doc "A time in the one timezone the whole surface uses; the date only when it is not today."
  def directory_time(%DateTime{} = at, now) do
    if DateTime.to_date(at) == DateTime.to_date(now),
      do: Calendar.strftime(at, "%H:%M UTC"),
      else: Calendar.strftime(at, "%d %b, %H:%M UTC")
  end

  def directory_time(_at, _now), do: "Not recorded"

  @doc """
  The one inspection target a message can truthfully claim, or nil.

  An operator or integration input is addressed by the retained id of the
  revision on screen. That route already resolves per input: its own request
  inspector before an episode exists, its own admission request once routed,
  and the recorded decision when it was ignored. A reply is addressed by the
  turn that produced it, the same work-request contract the episode page
  uses. Nothing is derived from the conversation's newest episode, the title,
  or the message's position.
  """
  def inspection_link(%{actor: actor, input_id: id} = message)
      when actor in [:operator, :integration] and is_binary(id) do
    href = "/timeline/ingress-input%3A#{id}"

    if is_binary(message[:episode_id]) or message[:status] in [:pending, :blocked],
      do: %{href: href, label: "View request"},
      else: %{href: href, label: "View decision"}
  end

  def inspection_link(%{actor: :ryker, episode_ref: episode_ref} = message)
      when is_binary(episode_ref) do
    path = "/timeline/" <> URI.encode_www_form(episode_ref)

    case message[:turn_id] do
      turn_id when is_binary(turn_id) ->
        %{href: path <> "?attempt=#{turn_id}#request-#{turn_id}", label: "View request"}

      _no_turn ->
        %{href: path, label: "View execution"}
    end
  end

  def inspection_link(_message), do: nil

  # Only states an operator has to act on or notice. "Sent" and "Delivered"
  # were the normal case on every line and said nothing.
  defp message_state(%{event_kind: :edit}), do: "edited"
  defp message_state(%{actor: :operator, status: :blocked}), do: "Needs attention"
  defp message_state(%{actor: :operator, execution: %{state: "blocked"}}), do: "Needs attention"

  defp message_state(%{actor: :operator}), do: nil
  defp message_state(%{actor: :integration}), do: nil
  defp message_state(%{status: :delivery_pending}), do: "Sending"
  defp message_state(%{status: status}) when status in [:settled, :delivered], do: nil
  defp message_state(%{status: status}), do: label(status)

  # Model work that stopped is a material failure of this message: it reads
  # beside the message with the same retry /failures offers, not nowhere. The
  # retry opens the HTTP confirmation page, so it is a plain link, not a live
  # navigation that would fail the socket join first.
  defp message_failure(%{actor: :operator, execution: %{state: "blocked", key: key}}) do
    path = "/actions/work/#{URI.encode_www_form(key)}/retry"
    %{label: "Model work stopped", retry: path, inspect: "/failures"}
  end

  defp message_failure(_message), do: nil

  defp message_working?(%{actor: :operator, execution: %{state: "working"}}), do: true
  defp message_working?(_message), do: false

  defp progress_by_input(snapshot) do
    snapshot
    |> Map.get(:admission_progress, [])
    |> Enum.group_by(& &1[:native_input_id])
  end

  defp actor(:operator), do: "You"
  defp actor(:integration), do: "Integration"
  defp actor(_), do: "Ryker"
end
