defmodule Ryker.ControlPlane.LabPage do
  @moduledoc """
  Direct conversations with the agent, through the normal durable action boundary.

  Two regions: a readable directory of retained conversations and the
  conversation itself. The index is an empty draft bound to a fresh identity,
  so nothing is written until the first message; an open conversation is the
  same view with its retained transcript. The composer sits at the bottom of
  the column in both, and the draft lists the examples above it. Each message
  links only its own retained execution. An open conversation redraws when
  anything in it changes (`subscriptions/1`).
  """
  use Phoenix.Component
  import Ryker.ControlPlane.Components
  alias Ryker.ControlPlane.{ConversationLab, Environments, FailureExplanation, HTML, Kit}
  alias Ryker.CoopFleet.ControlPlane.Workers
  alias Ryker.{Episodes, Settings}
  alias Ryker.Episodes.Words
  alias Ryker.Settings.Environment

  @doc """
  The topics an open conversation listens to, as the context functions that
  subscribe to them (`Ryker.ControlPlane.WorkbenchLive`): the conversation
  itself (its messages, their routing, the requests that answer them and its
  environment), the conversations listed beside it, the environments it can
  choose, and whether Chat can run (the settings the running system applied,
  and the workers). A draft listens to the conversation its first message
  will start.
  """
  def subscriptions(conversation_id) do
    conversation =
      case ConversationLab.conversation_ref(conversation_id) do
        {:ok, ref} -> [{Episodes, :subscribe_conversation, ["control_plane", ref]}]
        {:error, _invalid} -> []
      end

    conversation ++
      [
        {Episodes, :subscribe_conversations, ["control_plane"]},
        {Settings, :subscribe, []},
        {Settings, :subscribe_application, []},
        {Workers, :subscribe_workers, []}
      ]
  end

  # Authored UI examples approved on 2026-09-09, grouped on 2026-09-19 by what
  # Ryker does. They are hints for what an operator could write, not claims
  # about configured access. A new conversation lists them above the composer.
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

  # QA 2026-09-25: an example prompt in the empty box read as text someone
  # had already typed. The box says what it is for instead.
  @placeholder "Write a message to Ryker"

  def render(assigns) do
    assigns =
      assigns
      |> assign(:example_groups, @example_groups)
      |> assign(:placeholder, @placeholder)
      |> assign_new(:filter, fn -> "" end)
      |> assign_new(:environments, fn -> [] end)
      |> assign_new(:environment, fn -> nil end)
      |> assign_new(:environment_saved, fn -> nil end)
      |> then(&assign(&1, :days, directory_days(filtered(&1.items, &1.filter), &1.now)))
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
        <form
          :if={@items != []}
          id="lab-directory-search"
          class="lab-directory-search"
          role="search"
          phx-change="filter-conversations"
          phx-submit="filter-conversations"
        >
          <label class="sr-only" for="lab-directory-filter">Search conversations</label>
          <input
            id="lab-directory-filter"
            type="search"
            name="q"
            value={@filter}
            placeholder="Search conversations"
            autocomplete="off"
            phx-debounce="120"
          />
        </form>
        <div class="lab-directory-list">
          <section :if={@snapshot[:draft]} class="lab-directory-day lab-directory-draft">
            <span class="lab-directory-item" aria-current="page"><span class="lab-directory-title">New conversation</span><span class="lab-directory-meta"><Kit.state
              tone={:off}
              word="Not sent yet"
            /></span></span>
          </section>
          <div :if={@items == [] and !@snapshot[:draft]} class="lab-directory-empty">
            <strong>No conversations yet</strong>
            <p>Send a message and it will appear here.</p>
          </div>
          <p :if={@items != [] and @days == []} class="lab-directory-empty">
            No conversation matches “{@filter}”.
          </p>
          <section :for={{day, items} <- @days} class="lab-directory-day">
            <h2 :if={day}>{day}</h2>
            <.link
              :for={item <- items}
              navigate={"/conversations/#{item.id}"}
              class="lab-directory-item"
              title={item.title}
              aria-current={if item.id == @selected, do: "page"}
            ><span class="lab-directory-title">{item.title}</span><time
              class="lab-directory-time"
              datetime={DateTime.to_iso8601(item.updated_at)}
              title={directory_time(item.updated_at, @now)}
            >{Kit.clock(item.updated_at)} UTC</time><span class="lab-directory-meta"><.directory_state status={
              item[:status]
            } /><.directory_environment ref={item[:environment_ref]} choices={@environments} /></span></.link>
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
                conversation={@snapshot.conversation_id}
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
                <input
                  id="lab-attachments"
                  name="attachments[]"
                  type="file"
                  multiple
                  accept="image/png,image/jpeg,image/webp,image/gif,application/pdf,text/*,application/json,application/yaml,application/x-yaml,audio/*,video/mp4,video/quicktime,video/webm,.log,.yml,.yaml,.toml,.conf,.ini,.sh,.sql,.diff,.patch,.m4a,.opus"
                  aria-describedby="lab-attachments-error"
                /><label class="lab-attach" for="lab-attachments">Attach files</label><span
                  class="lab-attached"
                  aria-live="polite"
                ></span><button class="ui-button primary" type="submit" disabled>
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
            <div class="lab-composer-foot">
              <.environment_choice
                environments={@environments}
                environment={@environment}
                saved={@environment_saved}
              />
              <p :if={@chat_ready} class="lab-chat-footer">⌘ / Ctrl + Enter to send</p>
            </div>
          </div>
        </div>
      </section>
    </div>
    """
  end

  attr(:environments, :list, required: true, doc: "What environment_choices/1 offers")

  attr(:environment, :string,
    default: nil,
    doc: "The ref of the conversation's environment; nil is no environment"
  )

  attr(:saved, :any, default: nil, doc: "Which choice was just saved, for Kit.saved/1")

  # Where the conversation works, chosen under the message box it applies to
  # and saved as it changes. It sat in a head of its own above the messages
  # until Andrew, 2026-09-27: "this can be cleanly and nicely moved to text
  # input form or under it, so we don't waste space on top bar with huge
  # dropdown". It stays outside the message form, which the page never
  # redraws, so it always shows what is saved. With no environment to
  # choose, it says so and where to add one, so the choice can be found at
  # all (2026-09-26: "how can I select which environment to use?").
  defp environment_choice(assigns) do
    ~H"""
    <form
      :if={@environments != []}
      id="lab-environment-form"
      class="lab-environment"
      phx-change="select-conversation-environment"
      phx-submit="select-conversation-environment"
    >
      <label for="lab-environment">Environment</label>
      <select id="lab-environment" name="environment">
        <option
          :for={choice <- @environments}
          value={choice.ref}
          selected={choice.ref == @environment}
        >
          {choice.name}
        </option>
        <option value="" selected={is_nil(@environment)}>No environment</option>
      </select>
      <Kit.saved id="lab-environment-saved" key={@saved} />
    </form>
    <p :if={@environments == []} class="lab-environment lab-environment-none">
      <span class="lab-environment-label">Environment</span>
      <span>None yet</span>
      <span aria-hidden="true">·</span>
      <.link navigate="/environments/new">Add one</.link>
    </p>
    """
  end

  @doc """
  The environments Chat offers under its message box, from a settings snapshot: the default
  first, each with the repositories it holds as people know them and whether
  it has an Emisar account.
  """
  @spec environment_choices(map()) :: [map()]
  def environment_choices(snapshot) do
    snapshot.environments
    |> Environments.ordered()
    |> Enum.map(fn environment ->
      %{
        ref: environment.ref,
        name: environment.display_name,
        default: environment.is_default,
        repositories:
          environment
          |> Environment.repository_refs()
          |> Enum.map(&Environments.repository_name(snapshot, &1)),
        emisar: is_binary(environment.emisar_connection_ref)
      }
    end)
  end

  attr(:id, :string, required: true)
  attr(:message, :map, required: true)
  attr(:now, :any, required: true)
  attr(:progress, :map, required: true)
  attr(:conversation, :string, default: nil)

  defp chat_message(assigns) do
    rows = Map.get(assigns.progress, assigns.message[:native_input_id], [])
    {stopped, live} = Enum.split_with(rows, &(&1.phase == "Needs attention"))

    assigns =
      assigns
      |> assign(:timeline, timeline_href(assigns.message))
      |> assign(:state, message_state(assigns.message))
      |> assign(:failure, message_failure(assigns.message, assigns.conversation))
      |> assign(:stopped, Enum.map(stopped, &routing_failure(&1, assigns.conversation)))
      |> assign(:rows, live)
      |> assign(:typing, rows == [] and message_working?(assigns.message))

    ~H"""
    <article id={@id} class={"lab-chat-message actor-#{@message.actor}"}>
      <span class="lab-avatar" aria-hidden="true"><img
        :if={@message.actor not in [:operator, :integration]}
        src="/assets/brand/mark-mint.svg"
        alt=""
      /><span :if={@message.actor in [:operator, :integration]}>{String.first(actor(@message.actor))}</span></span>
      <div class="lab-message-byline">
        <strong>{actor(@message.actor)}</strong><time datetime={
          DateTime.to_iso8601(@message.occurred_at)
        }>{directory_time(
          @message.occurred_at,
          @now
        )}</time><span :if={@state} class="lab-message-state">{@state}</span><span
          :if={@message[:answered_earlier]}
          class="lab-message-state"
        >Answered your earlier wording</span>{Phoenix.HTML.raw(HTML.lab_message_actions(@message))}<a
          :if={@timeline}
          href={@timeline}
          target="_blank"
          rel="noopener"
          class="lab-message-inspect"
        >Timeline <span aria-hidden="true">↗</span><span class="sr-only"> (opens in a new tab)</span></a>
      </div>
      <div class="chat-message-text markdown-preview">
        {Phoenix.HTML.raw(Ryker.ControlPlane.SlackMarkdown.preview(@message.text || ""))}
      </div>
      {Phoenix.HTML.raw(HTML.lab_message_editor(@message))}
      <div class="chat-message-extras">{Phoenix.HTML.raw(HTML.lab_message_extras(@message))}</div>
      {Phoenix.HTML.raw(HTML.lab_message_reactions(@message))}
      <p :if={@failure} class="lab-message-failure" role="status">
        <span>{@failure.label}</span> <a href={@failure.retry}>Retry</a>
        <.link navigate={@failure.inspect}>Inspect cause</.link>
      </p>
      <p :for={failure <- @stopped} class="lab-message-failure" role="status">
        <span>{failure.label}</span> <a href={failure.retry}>Retry</a>
        <.link navigate={failure.inspect}>Inspect cause</.link>
      </p>
      <p
        :for={row <- @rows}
        id={"lab-progress-#{row.id}"}
        class="lab-message-progress"
        data-phase={row.phase}
        role="status"
      >
        <span class="lab-progress-dot" aria-hidden="true"></span><span class="lab-progress-status">{live_phase(
          row.phase
        )}</span><span
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
        <span class="lab-progress-dot" aria-hidden="true"></span>
        <span>Ryker is working on a reply</span>
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
  Retained conversations under the day each last changed, newest first, with
  the headings every Kit list uses: Today, Yesterday, a weekday within the
  week, then the date (`Kit.day_groups/3`).

  Days come from the observed UTC clock; nothing here invents a summary or a
  count. Items keep the projection's order inside their day.
  """
  @spec directory_days([map()], DateTime.t()) :: [{String.t() | nil, [map()]}]
  def directory_days(items, now) do
    items
    |> Enum.zip(Kit.day_groups(items, & &1.updated_at, now))
    |> Enum.reduce([], fn
      {item, nil}, [{day, rows} | days] -> [{day, [item | rows]} | days]
      {item, day}, days -> [{day, [item]} | days]
    end)
    |> Enum.reduce([], fn {day, rows}, days -> [{day, Enum.reverse(rows)} | days] end)
  end

  @doc "A time in the one timezone the whole surface uses; the date only when it is not today."
  def directory_time(%DateTime{} = at, now) do
    if DateTime.to_date(at) == DateTime.to_date(now),
      do: Calendar.strftime(at, "%H:%M UTC"),
      else: Calendar.strftime(at, "%d %b, %H:%M UTC")
  end

  def directory_time(_at, _now), do: "Not recorded"

  @doc """
  The one timeline a message can truthfully link, or nil.

  An operator or integration input is addressed by the retained id of the
  revision on screen. That route already resolves per input: its own request
  inspector before an episode exists, its own admission request once routed,
  and the recorded decision when it was ignored. A reply is addressed by the
  turn that produced it, the same work-request contract the episode page
  uses. A quick reply, which routing sent without Work, links the input it
  answered. Nothing is derived from the conversation's newest episode, the
  title, or the message's position.
  """
  def timeline_href(%{actor: actor, input_id: id})
      when actor in [:operator, :integration] and is_binary(id),
      do: "/timeline/ingress-input%3A#{id}"

  def timeline_href(%{actor: :ryker, episode_ref: episode_ref} = message)
      when is_binary(episode_ref) do
    path = "/timeline/" <> URI.encode_www_form(episode_ref)

    case message[:turn_id] do
      turn_id when is_binary(turn_id) -> path <> "?attempt=#{turn_id}#request-#{turn_id}"
      _no_turn -> path
    end
  end

  def timeline_href(%{actor: :ryker, input_id: id}) when is_binary(id),
    do: "/timeline/ingress-input%3A#{id}"

  def timeline_href(_message), do: nil

  # Only states an operator has to act on or notice. "Sent" and "Delivered"
  # were the normal case on every line and said nothing.
  defp message_state(%{event_kind: :edit}), do: "edited"
  defp message_state(%{actor: :operator, status: :blocked}), do: "Needs attention"
  defp message_state(%{actor: :operator, execution: %{state: "blocked"}}), do: "Needs attention"

  defp message_state(%{actor: :operator}), do: nil
  defp message_state(%{actor: :integration}), do: nil
  defp message_state(%{status: :delivery_pending}), do: "Sending"
  defp message_state(%{status: status}) when status in [:settled, :delivered], do: nil
  defp message_state(%{status: status}), do: Words.label(status)

  # Model work that stopped is a material failure of this message: it reads
  # beside the message with the same retry /failures offers, not nowhere. The
  # retry opens the HTTP confirmation page, so it is a plain link, not a live
  # navigation that would fail the socket join first, and it comes back to
  # this conversation.
  defp message_failure(
         %{actor: :operator, execution: %{state: "blocked", key: key}},
         conversation
       ) do
    back =
      if conversation, do: "?" <> URI.encode_query(%{"back" => "/conversations/#{conversation}"})

    path = "/actions/work/#{URI.encode_www_form(key)}/retry#{back}"
    %{label: "Model work stopped", retry: path, inspect: "/failures"}
  end

  defp message_failure(_message, _conversation), do: nil

  # Routing that stopped is a failure of the message like stopped work: its
  # cause and the retry Failures offers read beside it, and its clock stops.
  # The live install, 2026-09-26, showed "Routing stopped 260m 45s" for
  # hours, with nothing to do about it.
  defp routing_failure(row, conversation) do
    back =
      if conversation, do: "?" <> URI.encode_query(%{"back" => "/conversations/#{conversation}"})

    failure = %{action: :rearm, kind: "admission", ref: row.ref}

    %{
      label: if(row.cause, do: "Routing stopped: " <> row.cause, else: "Routing stopped"),
      retry: FailureExplanation.action_path(failure) <> (back || ""),
      inspect: FailureExplanation.path(failure)
    }
  end

  defp message_working?(%{actor: :operator, execution: %{state: "working"}}), do: true
  defp message_working?(_message), do: false

  defp progress_by_input(snapshot) do
    snapshot
    |> Map.get(:admission_progress, [])
    |> Enum.group_by(& &1[:native_input_id])
  end

  # What the live line says while routing handles the message; the phase names
  # come from the observed admission attempt.
  defp live_phase("Queued"), do: "Waiting to route your message"
  defp live_phase("Retrying"), do: "Retrying routing"
  defp live_phase(_phase), do: "Routing your message"

  attr(:status, :atom, default: nil)

  # What a conversation needs from the reader, as the Kit's dot and word:
  # Ryker at work is busy, anything that needs a person warns, a reply is quiet.
  defp directory_state(assigns) do
    {tone, word} = directory_status(assigns.status)
    assigns = assign(assigns, tone: tone, word: word)

    ~H"""
    <Kit.state tone={@tone} word={@word} />
    """
  end

  attr(:ref, :string, default: nil)
  attr(:choices, :list, required: true)

  # Where the conversation works, after its state (2026-09-26, "Each
  # conversation shows its environment"): the environment its head shows, or
  # "No environment". With no environments at all there is nothing to tell
  # conversations apart by, so the row says nothing.
  defp directory_environment(assigns) do
    assigns = assign(assigns, :name, environment_name(assigns.ref, assigns.choices))

    ~H"""
    <span :if={@name} class="lab-directory-environment"><span aria-hidden="true">·</span> {@name}</span>
    """
  end

  defp environment_name(_ref, []), do: nil

  defp environment_name(ref, choices) do
    case Enum.find(choices, &(&1.ref == ref)) do
      %{name: name} -> name
      nil -> "No environment"
    end
  end

  defp directory_status(:working), do: {:busy, "Working"}
  defp directory_status(:attention), do: {:warn, "Needs attention"}
  defp directory_status(:waiting_for_you), do: {:warn, "Waiting for you"}
  defp directory_status(:waiting), do: {:busy, "Waiting"}
  defp directory_status(_status), do: {:off, "Replied"}

  defp filtered(items, filter) when filter in [nil, ""], do: items

  defp filtered(items, filter) do
    needle = String.downcase(String.trim(filter))
    Enum.filter(items, &String.contains?(String.downcase(&1.title || ""), needle))
  end

  defp actor(:operator), do: "You"
  defp actor(:integration), do: "Integration"
  defp actor(_), do: "Ryker"
end
