defmodule Responder.ControlPlane.HTML do
  alias Responder.ControlPlane.Card
  alias Responder.ControlPlane.CodeEditingSetup
  alias Responder.ControlPlane.Components
  alias Responder.ControlPlane.FailurePage
  alias Responder.ControlPlane.FindingsPage
  alias Responder.ControlPlane.SlackNames
  alias Responder.ControlPlane.SubscriptionPresentation
  alias Responder.ControlPlane.SubscriptionsPage
  alias Responder.ControlPlane.UsagePage
  alias Responder.ControlPlane.UsageProjection
  @moduledoc false

  @spec page(String.t(), String.t() | nil, iodata()) :: binary()
  alias Phoenix.HTML.Safe
  alias Responder.ControlPlane.ConfigurationHelp
  alias Responder.ControlPlane.Layouts
  alias Responder.ControlPlane.MemoryPage
  alias Responder.ControlPlane.SlackMarkdown

  # The title and description are the shell's header; the body owns the rest.
  def page(title, description, body) do
    %{__changed__: nil, title: title, description: description, body: IO.iodata_to_binary(body)}
    |> Layouts.static()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  def overview(%{counts: counts, needs_attention: attention} = snapshot) do
    cards =
      ([
         {"Active", Map.get(counts, :active, 0)},
         {"Waiting", Map.get(counts, :waiting, 0)},
         {"Blocked", Map.get(counts, :blocked, 0)},
         {"Delivery pending", Map.get(counts, :delivery_pending, 0)}
       ] ++ progress_cards(Map.get(snapshot, :progress)) ++ fleet_cards(Map.get(snapshot, :fleet)))
      |> Enum.map(fn {label, value} ->
        [
          "<article class=\"metric\"><strong>",
          escape(value),
          "</strong><span>",
          escape(label),
          "</span></article>"
        ]
      end)

    [
      "<section class=\"metrics\">",
      cards,
      "</section><section><h2>What needs attention</h2>",
      attention_list(attention),
      "</section>"
    ]
  end

  defp fleet_cards(%{required: true, unavailable: true}) do
    [{"Fleet health", "unavailable"}]
  end

  defp fleet_cards(%{required: true} = fleet) do
    [
      {"Eligible Coop workers", Map.get(fleet, :eligible_workers, 0)},
      {"Free turn slots", get_in(fleet, [:capacity, :turn, :free]) || 0},
      {"Current placements", Map.get(fleet, :current_placements, 0)}
    ]
  end

  defp fleet_cards(_direct_or_missing), do: []

  defp progress_cards(%{admission: admission, slack_status: slack_status}) do
    [
      {"Admission queued", Map.get(admission, :queued, 0)},
      {"Admission deciding", Map.get(admission, :admitting, 0)},
      {"Admission retrying", Map.get(admission, :retrying, 0)},
      {"Oldest active admission", duration(Map.get(admission, :oldest_active_ms, 0))},
      {"Slack status writes pending", Map.get(slack_status, :pending, 0)},
      {"Oldest Slack status write", duration(Map.get(slack_status, :oldest_pending_ms, 0))}
    ]
  end

  defp progress_cards(_missing), do: []

  def lab_index(items) do
    rows =
      Enum.map(items, fn item ->
        [
          "<tr><td><a href=\"/conversations/",
          segment(item.id),
          "\"><code>",
          escape(item.id),
          "</code></a></td><td>",
          integer(item.message_count),
          "</td><td>",
          timestamp(item.updated_at),
          "</td></tr>"
        ]
      end)

    [
      "<section class=\"lab-hero\"><div><p class=\"eyebrow\">Real runtime · local surface</p>",
      "<h2>Talk to Responder without posting to Slack</h2>",
      "<p>Messages enter the ordinary ingress, admission, episode, Work, state-tool, and delivery pipeline. Restart recovery and policy boundaries are identical to platform traffic.</p></div>",
      "<a class=\"button\" href=\"/conversations/new\">Start conversation</a></section>",
      "<section><h2>Recent conversations</h2>",
      table(["Conversation", "Conversation inputs", "Updated"], rows),
      "</section>"
    ]
  end

  def lab_conversation(snapshot, csrf_token) do
    messages =
      case snapshot.messages do
        [] -> "<p class=\"empty\">Send the first message to begin this durable conversation.</p>"
        rows -> Enum.map(rows, &lab_message/1)
      end

    episodes =
      Enum.map(snapshot.episodes, fn episode ->
        [
          "<li><a href=\"/timeline/",
          segment(episode.ref),
          "\">",
          escape(episode.ref),
          "</a><span>",
          escape(episode.state),
          " · ",
          escape(episode.next_action),
          "</span>",
          if(episode.work_status == :blocked,
            do: [
              "<a class=\"quiet-link\" href=\"/failures/work/",
              segment(episode.ref),
              "\">Review failure</a>"
            ],
            else: ""
          ),
          "</li>"
        ]
      end)

    [
      "<section class=\"lab-shell\"><div class=\"lab-heading\"><div><p class=\"eyebrow\">Conversation</p><h2>Local model conversation</h2>",
      "<p><code>",
      escape(snapshot.conversation_id),
      "</code></p></div><div class=\"status-cluster\" data-lab-status aria-live=\"polite\">",
      status_badge(snapshot),
      "<a class=\"quiet-link\" href=\"/conversations/",
      segment(snapshot.conversation_id),
      "\">Refresh</a></div></div>",
      "<p class=\"lab-safety-note\"><strong>Same conversational product as Slack.</strong> Messages, attachments, generated images, state and Emisar tools, questions, waits, tasks, local incidents, publication cards, confirmation controls, reactions, and additional posts use the same durable runtime. Slack-owned API effects are emulated and labelled here; repository and Emisar authority still follows the configured Work policy.</p>",
      "<div class=\"lab-stream\" data-lab-stream data-live=\"",
      if(snapshot.live, do: "true", else: "false"),
      "\" aria-live=\"polite\"><div class=\"messages\">",
      messages,
      "</div><aside class=\"custody-strip\"><strong>Durable custody</strong>",
      lab_admission_progress(Map.get(snapshot, :admission_progress, [])),
      if(episodes == [] and Map.get(snapshot, :admission_progress, []) == [],
        do: "<p>Awaiting admission.</p>",
        else: ["<ul>", episodes, "</ul>"]
      ),
      "</aside></div>",
      "<form id=\"lab-composer\" phx-update=\"ignore\" class=\"composer\" method=\"post\" enctype=\"multipart/form-data\" action=\"/conversations/",
      segment(snapshot.conversation_id),
      "/messages\"><input type=\"hidden\" name=\"_token\" value=\"",
      escape(csrf_token),
      "\"><label for=\"lab-message\">Message</label>",
      "<textarea id=\"lab-message\" name=\"message\" maxlength=\"20000\" data-max-bytes=\"20000\" rows=\"5\" placeholder=\"Ask Responder to investigate, explain, remember, schedule, or continue work…\"></textarea>",
      "<label class=\"attachment-label\" for=\"lab-attachments\">Attachments</label>",
      "<input class=\"attachment-input\" id=\"lab-attachments\" name=\"attachments[]\" type=\"file\" multiple accept=\"image/png,image/jpeg,image/webp,image/gif,text/plain,text/markdown,text/csv,application/json,application/yaml,application/x-yaml,application/pdf\">",
      "<p class=\"composer-status\" role=\"status\" hidden></p><div class=\"composer-actions\"><span>Message or up to 2 files · 8 MiB total · durable on submit</span><button type=\"submit\">Send through Responder</button></div></form></section>",
      "<script src=\"/static/lab.js\" defer></script>"
    ]
  end

  def lab_task_record(snapshot, back_path) do
    navigation =
      Enum.map(snapshot.navigation, fn item ->
        ["<a class=\"button\" href=\"", escape(item.path), "\">", escape(item.label), "</a>"]
      end)

    [
      "<section class=\"work-view\"><p class=\"eyebrow\">Host-rendered task record</p>",
      "<pre>",
      escape(snapshot.body),
      "</pre><div class=\"work-view-actions\">",
      "<a class=\"quiet-link\" href=\"",
      escape(back_path),
      "\">Back to conversation</a>",
      navigation,
      "</div></section>"
    ]
  end

  def lab_javascript do
    """
    (() => {
      const form = document.querySelector('.composer');
      const message = document.querySelector('#lab-message');
      const attachments = document.querySelector('#lab-attachments');

      if (form && message) {
        message.addEventListener('input', () => message.setCustomValidity(''));
        form.addEventListener('submit', (event) => {
          const maximum = Number(message.dataset.maxBytes);
          const bytes = new TextEncoder().encode(message.value).byteLength;
          const files = attachments ? Array.from(attachments.files) : [];
          const fileBytes = files.reduce((total, file) => total + file.size, 0);
          let error = '';
          if (bytes > maximum) error = `Message is ${bytes.toLocaleString()} bytes; maximum is ${maximum.toLocaleString()}.`;
          else if (message.value.trim() === '' && files.length === 0) error = 'Write a message or attach a file.';
          else if (files.length > 2) error = 'Attach at most 2 files.';
          else if (fileBytes > 8 * 1024 * 1024) error = 'Attachments must total at most 8 MiB.';
          if (error === '') return;
          event.preventDefault();
          message.setCustomValidity(error);
          message.reportValidity();
        });
      }

      const nearConversationEnd = () =>
        document.documentElement.scrollHeight - (window.scrollY + window.innerHeight) < 240;

      const followLatest = () => {
        const currentComposer = document.querySelector('.composer');
        if (currentComposer) currentComposer.scrollIntoView({block: 'end'});
      };

      if (!window.location.hash) window.requestAnimationFrame(followLatest);

      // LiveView owns this DOM when mounted in the live shell. Keep only the
      // legacy form validation above; never run a competing HTML polling loop.
      if (document.getElementById('operator-page')) return;

      const initial = document.querySelector('[data-lab-stream]');
      if (!initial || initial.dataset.live !== 'true') return;

      const poll = async () => {
        if (document.hidden) {
          window.setTimeout(poll, 1500);
          return;
        }

        try {
          const response = await window.fetch(window.location.href, {
            cache: 'no-store',
            credentials: 'same-origin',
            headers: {'accept': 'text/html'}
          });
          if (!response.ok) throw new Error('refresh failed');
          const documentCopy = new DOMParser().parseFromString(await response.text(), 'text/html');
          const next = documentCopy.querySelector('[data-lab-stream]');
          const current = document.querySelector('[data-lab-stream]');
          if (!next || !current) return;
          const shouldFollow = nearConversationEnd();
          const changed = next.innerHTML !== current.innerHTML;
          const nextStatus = documentCopy.querySelector('[data-lab-status]');
          const currentStatus = document.querySelector('[data-lab-status]');
          if (nextStatus && currentStatus) currentStatus.replaceWith(nextStatus);
          current.replaceWith(next);
          if (changed && shouldFollow) window.requestAnimationFrame(followLatest);
          if (next.dataset.live === 'true') window.setTimeout(poll, 1500);
        } catch (_error) {
          window.setTimeout(poll, 3000);
        }
      };

      window.setTimeout(poll, 1200);
    })();
    """
  end

  def incidents(items, params \\ %{}) do
    rows =
      Enum.map(items, fn item ->
        [
          "<tr><td><a href=\"/incident-rooms/",
          segment(item.ref),
          "\">",
          escape(item.title),
          "</a><br><code>",
          escape(item.ref),
          "</code></td><td>",
          escape(item.status),
          "</td><td>",
          escape(item.repository_ref),
          "</td><td>",
          escape(channel_label(item.workspace_ref, item.channel_ref)),
          "</td><td>",
          escape(item.publication_status || "none"),
          "</td><td>",
          timestamp(item.updated_at),
          "</td></tr>"
        ]
      end)

    [
      search_form(
        "/incident-rooms",
        "Title, room, repository or channel",
        params,
        ~w(requested ready blocked closed)
      ),
      table(["Incident room", "Status", "Repository", "Channel", "Publication", "Updated"], rows)
    ]
  end

  def incident(%{room: room, lifecycle: lifecycle, records: records, publication: publication}) do
    lifecycle_rows =
      Enum.map(lifecycle, fn event ->
        [
          "<tr><td>",
          timestamp(event.occurred_at),
          "</td><td>",
          escape(event.kind),
          "</td><td>",
          escape(event.channel_ref),
          "</td></tr>"
        ]
      end)

    record_rows =
      Enum.map(records, fn record ->
        [
          "<tr><td><code>",
          escape(record.ref),
          "</code></td><td>",
          escape(record.kind),
          "</td><td>",
          escape(record.status),
          "</td><td>",
          escape(record.subject || "—"),
          "</td></tr>"
        ]
      end)

    [
      definition_list([
        {"Reference", room.ref},
        {"Status", room.status},
        {"Repository", room.repository_ref},
        {"Workspace", room.workspace_ref},
        {"Source channel", room.source_channel_ref},
        {"Incident channel", room.channel_ref || "not provisioned"},
        {"Channel state", room.channel_state},
        {"Visibility", if(room.private, do: "private", else: "public")},
        {"Source episode", {:safe, episode_link(room.source_episode_ref)}},
        {"Investigation episode", {:safe, episode_link(room.episode_ref)}},
        {"Requested", room.requested_at},
        {"Updated", room.updated_at}
      ]),
      "<section><h2>Room lifecycle</h2>",
      table(["At", "Observation", "Channel"], lifecycle_rows),
      "</section><section><h2>Evidence-backed records</h2>",
      table(["Record", "Kind", "Status", "Subject"], record_rows),
      "</section><section><h2>Publication</h2>",
      publication_detail(publication),
      "</section>"
    ]
  end

  @schedule_statuses ~w(active paused completed expired deleted)
  @subscription_statuses ~w(active resolved timed_out cancelled)

  # One comparison table: the schedule's name and where it posts, its status as
  # a word, the next occurrence as a readable time with its zone, and the exact
  # reference kept secondary. The shell owns the title and description.
  def schedules(items, params \\ %{}) do
    rows =
      Enum.map(items, fn item ->
        {label, tone} = schedule_status(item.status)

        [
          [
            "<a href=\"/schedules/",
            segment(item.ref),
            "\">",
            escape(item.title),
            "</a><span class=\"row-secondary\">",
            schedule_destination(item),
            "<code>",
            escape(item.ref),
            "</code></span>"
          ],
          dot_status(label, tone),
          schedule_next(item),
          escape(item.repository || "None"),
          integer(item.failures)
        ]
      end)

    [
      "<div class=\"schedules-page\">",
      search_form("/schedules", "Title, repository or destination", params, @schedule_statuses),
      cond do
        rows != [] ->
          [
            result_count(length(rows), "schedule", "schedules"),
            data_table(["Schedule", "Status", "Next occurrence", "Repository", "Failures"], rows)
          ]

        filtered?(params, @schedule_statuses) ->
          empty_state("No schedules match these filters.")

        true ->
          empty_state(
            "No schedules yet. A schedule is proposed and confirmed in a conversation; once confirmed it appears here with every dispatched or missed occurrence."
          )
      end,
      "</div>"
    ]
  end

  defp schedule_status(:active), do: {"Active", "active"}
  defp schedule_status(:paused), do: {"Paused", "quiet"}
  defp schedule_status(:completed), do: {"Completed", "done"}
  defp schedule_status(:expired), do: {"Expired", "quiet"}
  defp schedule_status(:deleted), do: {"Deleted", "quiet"}
  defp schedule_status(status), do: {Components.label(status), "quiet"}

  defp schedule_destination(%{destination_conversation_ref: ref}) when is_binary(ref),
    do: [escape(SlackNames.destination(ref)), " · "]

  defp schedule_destination(_item), do: []

  defp schedule_next(%{next_occurrence_at: %DateTime{} = at} = item),
    do: [
      readable_time(at),
      "<span class=\"row-secondary\">",
      escape(item.timezone || "UTC"),
      "</span>"
    ]

  defp schedule_next(_item), do: "None scheduled"

  def schedule(%{schedule: schedule, occurrences: occurrences}) do
    rows =
      Enum.map(occurrences, fn occurrence ->
        [
          "<tr><td>",
          timestamp(occurrence.scheduled_for),
          "</td><td>",
          escape(Map.get(occurrence, :trigger, :scheduled)),
          "</td><td>",
          escape(occurrence.status),
          "</td><td>",
          episode_link(occurrence.episode_ref),
          "</td><td>",
          escape(Map.get(occurrence, :episode_state) || "—"),
          " / ",
          escape(Map.get(occurrence, :turn_status) || "—"),
          "</td><td>",
          timestamp(Map.get(occurrence, :started_at)),
          " → ",
          timestamp(
            Map.get(occurrence, :delivered_at) || Map.get(occurrence, :finished_at) ||
              Map.get(occurrence, :accepted_at)
          ),
          "</td><td>",
          integer(Map.get(occurrence, :work_attempt_count, 0) || 0),
          "</td><td>",
          escape(occurrence_failure(occurrence)),
          "</td><td>",
          escape(occurrence.missed_reason || "—"),
          "</td></tr>"
        ]
      end)

    [
      "<div class=\"action-controls\">",
      schedule_controls(schedule),
      "<a href=\"/conversations\">Replace in a conversation…</a></div>",
      definition_list([
        {"Reference", schedule.ref},
        {"Status", schedule.status},
        {"Revision", schedule.revision},
        {"Recurrence", schedule.recurrence},
        {"Timezone", schedule.timezone},
        {"Authority", schedule.authority},
        {"Repository", schedule.repository || "none"},
        {"Destination", destination(schedule)},
        {"Next occurrence", schedule.next_occurrence_at},
        {"Expires", schedule.expires_at},
        {"Failures", schedule.failure_count},
        {"Last failure", schedule.last_error || "none"},
        {"Source episode", {:safe, episode_link(schedule.source_episode_ref)}}
      ]),
      "<section><h2>What it asks for</h2><pre class=\"record-body\">",
      escape(schedule.task),
      "</pre></section><section><h2>Execution history</h2>",
      table(
        [
          "Due",
          "Trigger",
          "Dispatch",
          "Episode",
          "Execution",
          "Timing",
          "Attempts",
          "Failure",
          "Reason"
        ],
        rows
      ),
      "</section>"
    ]
  end

  defp schedule_controls(schedule) do
    [
      if(schedule.status in [:active, :paused, :completed],
        do:
          Components.action_button(
            "/actions/schedule/#{segment(schedule.ref)}/run-now",
            "Run now",
            :primary
          ),
        else: []
      ),
      if(schedule.status in [:active, :paused],
        do: [
          Components.action_button(
            "/actions/schedule/#{segment(schedule.ref)}/#{if schedule.status == :active, do: "paused", else: "active"}",
            if(schedule.status == :active, do: "Pause", else: "Resume")
          ),
          Components.action_button(
            "/actions/schedule/#{segment(schedule.ref)}/deleted",
            "Delete",
            :danger
          )
        ],
        else: []
      )
    ]
  end

  # Waits keep their row layout (purpose, timing, collapsed technical details);
  # the shell adds the help, the one toolbar and the quiet count around it.
  def subscriptions(items, params \\ %{}) do
    [
      "<div class=\"subscriptions-page\">",
      page_help("waits-help", "How waits are listed and searched", [
        "<p>A wait is work that paused for a timer or for the next matching update from Slack, GitHub, Emisar or another source. Only that update, the timer or the wait’s own deadline resumes it; nothing here predicts what the source will report.</p>",
        "<p>This list shows up to 100 waits in the selected status, active waits first. Search narrows what is shown; an exact subscription reference finds that wait across all history within the status.</p>"
      ]),
      search_form(
        "/subscriptions",
        "Request, target, source or reference",
        params,
        @subscription_statuses,
        fn status ->
          {label, _tone} =
            SubscriptionPresentation.status(%{status: String.to_existing_atom(status)})

          label
        end
      ),
      if(items == [], do: [], else: result_count(length(items), "wait", "waits")),
      Safe.to_iodata(
        SubscriptionsPage.render(%{
          __changed__: nil,
          items: items,
          filtered: filtered?(params, @subscription_statuses)
        })
      ),
      "</div>"
    ]
  end

  # One comparison table of every channel Responder knows about. The name
  # links to the channel's detail; the workspace, kind and raw Slack ids sit
  # beneath it in small type, reachable without a tooltip.
  def channels(items, params \\ %{}) do
    rows =
      Enum.map(items, fn item ->
        {membership, tone} = channel_membership(item.membership)

        [
          [
            "<a href=\"/channels/",
            segment(item.workspace_ref),
            "/",
            segment(item.channel_ref),
            "\">",
            escape(SlackNames.name(item.workspace_ref, item.channel_ref)),
            "</a><span class=\"row-secondary\">",
            channel_identity(item),
            "</span>"
          ],
          dot_status(membership, tone),
          if(item.participation,
            do: escape(Components.label(item.participation)),
            else: "Not configured"
          ),
          if(item[:custom_instructions], do: "Global + channel", else: "Global only"),
          escape(item.repository_ref || "None"),
          integer(item.episodes),
          if(item.last_at, do: readable_time(item.last_at), else: "No activity recorded")
        ]
      end)

    [
      "<div class=\"channels-page\">",
      search_form("/channels", "Channel, workspace or repository", params),
      cond do
        rows != [] ->
          [
            result_count(length(rows), "channel", "channels"),
            data_table(
              [
                "Channel",
                "Membership",
                "Participation",
                "Instructions",
                "Repository",
                {"row-number", "Episodes"},
                "Last activity"
              ],
              rows
            )
          ]

        filtered?(params, []) ->
          empty_state("No channels match these filters.")

        true ->
          empty_state(
            "No channels yet. A channel appears here once it has configuration, membership, incident custody or recorded work."
          )
      end,
      "</div>"
    ]
  end

  defp channel_membership(:joined), do: {"Joined", "active"}
  defp channel_membership(nil), do: {"Not recorded", "quiet"}
  defp channel_membership(status), do: {Components.label(status), "quiet"}

  # Workspace name, kind, and whichever raw ids the display names do not
  # already spell out, so the exact identifiers stay on the page.
  defp channel_identity(item) do
    channel_name = SlackNames.name(item.workspace_ref, item.channel_ref)
    workspace_name = SlackNames.name(item.workspace_ref, item.workspace_ref)

    ids =
      [
        if(!String.contains?(workspace_name, item.workspace_ref), do: item.workspace_ref),
        if(!String.contains?(channel_name, item.channel_ref), do: item.channel_ref)
      ]
      |> Enum.reject(&is_nil/1)

    [escape(workspace_name), " · ", escape(channel_kind(item))] ++
      if(ids == [], do: [], else: [" · <code>", escape(Enum.join(ids, "/")), "</code>"])
  end

  # One comparison table: each repository's counts and last-used revision on
  # a row, with its access policy, frozen freshness receipt and worker
  # connections as details on demand directly beneath.
  def repositories(items, params \\ %{}) do
    rows =
      Enum.flat_map(items, fn item ->
        [
          [
            [
              "<strong>",
              escape(item.ref),
              "</strong><span class=\"row-secondary\"><a href=\"/activity?repository=",
              segment(item.ref),
              "\">View requests →</a></span>"
            ],
            integer(item.sessions),
            integer(item.channels),
            integer(item.schedules),
            integer(item.publications),
            repository_revision(item.freshness)
          ],
          {:details,
           [
             "<details><summary>Access and code revision</summary><p>Access: ",
             escape(policy_summary(item.configured)),
             " · <a href=\"/configuration\">Inspect configuration</a></p>",
             "<p>The revision is the saved execution snapshot, not a live Git check.</p>",
             freshness_detail(item.freshness),
             "</details><details><summary>Worker connections</summary>",
             worker_list(item.workers),
             "<p><a href=\"/configuration\">Inspect worker configuration →</a></p></details>"
           ]}
        ]
      end)

    [
      "<div class=\"repositories-page\">",
      search_form("/repositories", "Repository name", params),
      cond do
        rows != [] ->
          [
            result_count(length(items), "repository", "repositories"),
            data_table(
              [
                "Repository",
                {"row-number", "Work sessions"},
                {"row-number", "Channels"},
                {"row-number", "Schedules"},
                {"row-number", "PR workflows"},
                "Code revision"
              ],
              rows
            )
          ]

        filtered?(params, []) ->
          empty_state("No repositories match these filters.")

        true ->
          empty_state("No configured or observed repositories.")
      end,
      "</div>"
    ]
  end

  def memory(
        %{memories: memories} = snapshot,
        csrf_secret
      ) do
    reviews = Map.get(snapshot, :reviews, [])
    memory_rows = Enum.map(memories, &memory_row/1)
    review_rows = Enum.map(reviews, &review_row/1)

    [
      "<div class=\"memory-page\">",
      page_help("memory-help", "How memory works", [
        "<p>Current knowledge keeps one evolving summary per subject, with source-linked updates. When background learning is enabled, Responder maintains useful decisions, intentions and changes even when it does not reply, including in shadow mode. Not every message needs a new memory: a learning batch can finish with no change. Related topics are recalled for later routing and work. Source excerpts retain original message text; conversation handovers summarize completed work.</p>",
        "<p>To create or correct conversation knowledge, explain the fact or change in the original Slack conversation or direct conversation. Related updates maintain the same topic. Edits, deletions and expiry invalidate knowledge that depended on the old source; invalidated items remain inspectable but are not recalled. Retention follows the oldest supporting source, so a new update cannot keep an expired fact alive indefinitely.</p>",
        "<p>Learning activity below shows waiting messages, outcomes and the exact saved attempts. If a batch needs attention, inspect its error before granting one additional model start. A retry does not reset its spent starts or bypass source and execution checks.</p>",
        "<p>For a deliberate saved fact, ask Responder to remember it and confirm the proposal. When a question explicitly says the answer will be remembered, an operator's answer confirms that fact without another click. These global mappings apply across conversations in this installation and survive ordinary history cleanup. Operational memory shows each saved value and where it applies; use Forget to remove one. Knowledge is context, not an instruction, permission or proof of current health.</p>",
        "<p>Saved instructions live on their own pages: <a href=\"/rules\">Standing rules →</a> <a href=\"/preferences\">Preferences →</a> <a href=\"/guidance\">Guidance →</a></p>"
      ]),
      if(snapshot[:conversation_memory],
        do:
          MemoryPage.render(%{
            __changed__: nil,
            view: snapshot.conversation_memory,
            csrf_secret: csrf_secret
          })
          |> Safe.to_iodata(),
        else: []
      ),
      "<section class=\"operational-memory\"><h2>Operational memory</h2>",
      if(memory_rows == [],
        do: empty_state("No confirmed memory is active."),
        else:
          data_table(
            ["Subject", "Value", "Applies to", "Status", {"row-action", "Action"}],
            memory_rows
          )
      ),
      "</section><section class=\"memory-review\"><h2>Memory review</h2>",
      if(review_rows == [],
        do: empty_state("No stale or duplicate memories need review."),
        else: data_table(["Kind", "Entries", "Reason", {"row-action", "Action"}], review_rows)
      ),
      "</section></div>"
    ]
  end

  defp memory_row(item) do
    [
      escape(item.subject),
      escape(item.value),
      [
        escape(String.capitalize(to_string(item.scope))),
        if(item.applicability, do: [" · ", escape(item.applicability)], else: [])
      ],
      escape(Components.label(to_string(item.status))),
      Components.action_button("/actions/memory/#{segment(item.ref)}/forget", "Forget", :danger)
    ]
  end

  defp review_row(review) do
    ref = segment(review["review_ref"])

    [
      escape(Components.label(to_string(review["kind"]))),
      Enum.map_join(review["entries"], "<br>", &review_entry/1),
      escape(review["reason"]),
      review_actions(review["kind"], ref)
    ]
  end

  defp review_entry(entry) do
    [
      "<strong>",
      escape(entry["subject"]),
      "</strong>: <code>",
      escape(entry["value"] || "(redacted)"),
      "</code><br><small>scope ",
      escape(entry["scope"] || "unknown"),
      " (",
      escape(entry["scope_ref"] || "unknown"),
      "); visibility ",
      escape(entry["visibility"] || "unknown"),
      "; saved ",
      escape(entry["confirmed_at"] || "unknown"),
      "; last used ",
      escape(entry["last_recalled_at"] || "never"),
      "; uses ",
      escape(to_string(entry["recall_count"] || 0)),
      "</small>"
    ]
  end

  defp review_actions(kind, ref) do
    [
      "<div class=\"action-controls\">",
      Components.action_button(
        "/actions/memory-review/#{ref}/keep",
        if(kind == "duplicate", do: "Keep separate", else: "Keep"),
        :primary
      ),
      review_secondary_action(kind, ref),
      Components.action_button("/actions/memory-review/#{ref}/forget", "Forget", :danger),
      "</div>"
    ]
  end

  defp review_secondary_action("duplicate", ref),
    do: Components.action_button("/actions/memory-review/#{ref}/merge", "Merge")

  defp review_secondary_action(_kind, ref),
    do: Components.action_button("/actions/memory-review/#{ref}/edit", "Edit")

  def memory_edit(review, action, token) do
    entry = hd(review["entries"])

    [
      "<section class=\"confirm\"><h2>Edit reviewed memory</h2><p>",
      escape(review["reason"]),
      "</p><form method=\"post\" action=\"",
      escape(action),
      "\"><input type=\"hidden\" name=\"_token\" value=\"",
      escape(token),
      "\"><label>Subject<input name=\"subject\" maxlength=\"120\" required value=\"",
      escape(entry["subject"]),
      "\"></label><label>Value<textarea name=\"value\" maxlength=\"4000\" required>",
      escape(entry["value"]),
      "</textarea></label><button type=\"submit\">Save edit</button>",
      " <a href=\"/memory\">Cancel</a></form></section>"
    ]
  end

  def confirmation(title, explanation, action, token, cancel_path) do
    [
      "<section class=\"confirm\" aria-label=\"",
      escape(title),
      "\"><p>",
      escape(explanation),
      "</p><form class=\"action-controls\" method=\"post\" action=\"",
      escape(action),
      "\"><input type=\"hidden\" name=\"_token\" value=\"",
      escape(token),
      "\"><button class=\"ui-button primary\" type=\"submit\">Confirm</button> ",
      "<a href=\"",
      escape(cancel_path),
      "\">Cancel</a></form></section>"
    ]
  end

  def failures([]) do
    [failure_summary([]), "<p class=\"empty\">Nothing needs attention.</p>"]
    |> IO.iodata_to_binary()
  end

  def failures(rows) do
    body =
      Enum.map(rows, fn row ->
        [
          "<article class=\"failure-card\"><div class=\"failure-card-top\"><h3 title=\"",
          escape(row.ref),
          "\">",
          escape(failure_kind(row.kind)),
          "</h3>",
          readable_time(row.updated_at),
          "</div><p title=\"",
          escape(row.summary),
          "\">",
          escape(FailurePage.cause(row)),
          "</p><div class=\"failure-card-actions\"><a href=\"/failures/",
          segment(row.kind),
          "/",
          segment(row.ref),
          "\">",
          "Inspect cause",
          "</a>",
          failure_episode(row),
          "<span title=\"",
          escape(Map.get(row, :destination)),
          "\">",
          escape(SlackNames.destination(Map.get(row, :destination)) || ""),
          "</span>",
          "<span class=\"failure-attempts\"><strong>",
          integer(Map.get(row, :attempt_count, 0)),
          "</strong> ",
          if(row[:attempt_count] == 1, do: "attempt", else: "attempts"),
          "</span>",
          if(FailurePage.manual_repair?(row),
            do: "<span class=\"failure-repair-needed\">Cleanup paused</span>",
            else: failure_recovery_action(row)
          ),
          "</div></article>"
        ]
      end)

    [
      failure_summary(rows),
      "<div class=\"failure-cards\">",
      body,
      "</div>"
    ]
  end

  defp failure_summary(rows) do
    requests =
      rows
      |> Enum.map(&Map.get(&1, :episode_ref))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> length()

    counts = Enum.frequencies_by(rows, & &1.kind)

    types = [
      {"work", "Model work"},
      {"admission", "Routing"},
      {"delivery", "Delivery"},
      {"retention", "Cleanup"},
      {"slack_interaction", "Slack updates"},
      {"slack_incident", "Incident rooms"},
      {"emisar", "Approvals"},
      {"publication", "Publishing"}
    ]

    [
      "<dl class=\"failure-summary\" aria-label=\"Summary of listed failures\">",
      Enum.map([{"Failures", length(rows)}, {"Affected requests", requests}], fn {label, count} ->
        ["<div><dt>", escape(label), "</dt><dd>", integer(count), "</dd></div>"]
      end),
      "</dl><dl class=\"failure-types\" aria-label=\"Listed failures by type\">",
      Enum.map(types, fn {kind, label} ->
        count = Map.get(counts, kind, 0)

        [
          "<div",
          if(count > 0, do: " class=\"has-failures\"", else: ""),
          "><dt>",
          escape(label),
          "</dt><dd>",
          integer(count),
          "</dd></div>"
        ]
      end),
      "</dl>"
    ]
  end

  def failure(row) do
    %{
      __changed__: nil,
      row: row,
      title: failure_kind(row.kind),
      recovery: failure_recovery_action(row) |> IO.iodata_to_binary()
    }
    |> FailurePage.render()
    |> Safe.to_iodata()
  end

  defp failure_recovery_action(%{action: action} = row) when action in [:rearm, :retry] do
    Components.action_button(
      "/actions/#{segment(row.kind)}/#{segment(row.ref)}/#{action}",
      cond do
        row[:work_recovery] -> row.work_recovery.action_label
        FailurePage.manual_repair?(row) -> "Retry cleanup"
        true -> recovery_label(row.kind)
      end,
      :primary
    )
  end

  defp failure_recovery_action(_row), do: []

  # Worker storage and the exact next cleanup targets, as the related
  # operational sections beneath the working copies. Nothing here estimates a
  # byte no worker measured: a missing report is unknown, not zero.
  defp workspace_storage(%{budget: budget, preview: preview, workers: workers}) do
    worker_rows =
      Enum.map(workers, fn worker ->
        [
          ["<code>", escape(worker.id), "</code>"],
          measurement_label(worker),
          storage_bytes(worker.bytes["disposable_bytes"]),
          storage_bytes(worker.bytes["protected_bytes"]),
          storage_bytes(worker.bytes["unattributed_bytes"]),
          storage_bytes(worker.reclaimed_bytes),
          escape(allocation_label(worker))
        ]
      end)

    preview_rows =
      Enum.map(preview, fn item ->
        [
          [
            "<code>",
            escape(item.ref),
            "</code><span class=\"row-secondary\">",
            escape(item.repository || "Repository not recorded"),
            " · ",
            escape(item.target || "no remote session"),
            "</span>"
          ],
          escape(Atom.to_string(item.kind)),
          escape(item.reason),
          [escape(Integer.to_string(item.eligible_age_seconds)), " s"]
        ]
      end)

    [
      "<section class=\"workspace-storage\"><h2>Worker storage</h2><p>Budget: ",
      storage_bytes(budget[:disposable_bytes_limit]),
      " of inactive disposable forks per worker, reclaimed within ",
      escape(budget[:reclaim_target_seconds] || "an unset target"),
      " seconds of eligibility. Each worker measures its own filesystem; a stale heartbeat means a stale measurement.</p>",
      if(worker_rows == [],
        do: empty_state("No fleet worker has reported storage."),
        else:
          data_table(
            [
              "Worker",
              "Measurement",
              {"row-number", "Disposable"},
              {"row-number", "Protected"},
              {"row-number", "Unattributed"},
              {"row-number", "Reclaimed"},
              "New forks"
            ],
            worker_rows
          )
      ),
      "</section><section class=\"cleanup-preview\"><h2>Next cleanup targets</h2><p>Read-only preview of the exact sessions cleanup will act on next, oldest eligible first. Nothing here is deleted by looking at it.</p>",
      if(preview_rows == [],
        do: empty_state("Nothing is eligible for cleanup right now."),
        else:
          data_table(
            ["Working copy", "Kind", "What cleanup will do", {"row-number", "Eligible for"}],
            preview_rows
          )
      ),
      "</section>"
    ]
  end

  defp measurement_label(%{measurement: :unknown}), do: "no measurement reported"
  defp measurement_label(%{measurement: :stale}), do: "stale (worker heartbeat is stale)"

  defp measurement_label(%{measured_at: measured_at}),
    do: ["measured ", readable_time(measured_at)]

  defp allocation_label(%{allocation: "refused", refusal_reason: reason}),
    do: "refused: #{reason || "reported refused"}"

  defp allocation_label(%{allocation: "open"}), do: "accepted"
  defp allocation_label(_worker), do: "unknown"

  defp storage_bytes(nil), do: "unknown"

  defp storage_bytes(value) when is_integer(value) do
    escape(:erlang.float_to_binary(value / 1_073_741_824, decimals: 2) <> " GiB")
  end

  defp storage_bytes(value), do: escape(value)

  # Working copies as one comparison table with their confirmed cleanup
  # actions, then worker storage and the cleanup preview as the related
  # operational sections. The GET button only opens the existing confirmation;
  # its protected POST performs the discard or the resume.
  def workspaces(rows, storage) do
    body =
      Enum.map(rows, fn row ->
        {status, tone} = workspace_status(row.status)

        action =
          case row.action do
            :rearm ->
              Components.action_button(
                "/actions/retention/#{segment(row.ref)}/rearm",
                "Resume cleanup",
                :primary
              )

            :discard_unmerged ->
              Components.action_button(
                "/actions/retention/#{segment(row.ref)}/discard",
                "Discard unmerged",
                :danger
              )

            nil ->
              "Managed automatically"
          end

        [
          [
            "<strong>",
            escape(Map.get(row, :repository) || "Repository not recorded"),
            "</strong><span class=\"row-secondary\">",
            if(row[:episode_ref],
              do: [
                "<a class=\"workspace-request-title\" href=\"/timeline/",
                segment(row.episode_ref),
                "\">",
                workspace_request_label(row),
                "</a> · "
              ],
              else: []
            ),
            "<code>",
            escape(row.ref),
            "</code></span>"
          ],
          dot_status(status, tone),
          [
            "<span title=\"",
            escape(row.summary),
            "\">",
            escape(workspace_reason(row)),
            "</span>"
          ],
          escape(Components.label(to_string(row.state))),
          readable_time(row.updated_at),
          action
        ]
      end)

    [
      "<div class=\"workspaces-page\">",
      page_help("workspaces-help", "How working copies are kept and cleaned up", [
        "<p>These are the repository checkouts tasks work in, not Slack workspaces. Responder keeps unfinished or unmerged work safe: a copy with uncommitted or unpublished changes is preserved until cleanup is safe, and discarding unmerged commits always requires confirmation.</p>",
        "<p>Resume interrupted cleanup from the row. Workers measure their own filesystem for the storage figures below. A worker that reported nothing is unknown, not empty, and a stale heartbeat means a stale measurement.</p>"
      ]),
      if(body == [],
        do:
          empty_state(
            "No working copies right now. A checkout appears here while a task uses it and until cleanup has safely removed it."
          ),
        else: [
          result_count(length(body), "working copy", "working copies"),
          data_table(
            [
              "Working copy",
              "Lifecycle",
              "What happens next",
              "Request",
              "Updated",
              {"row-action", "Action"}
            ],
            body
          )
        ]
      ),
      workspace_storage(storage),
      "</div>"
    ]
  end

  defp workspace_request_label(row) do
    title = row[:request_title] || "Open request →"

    case SlackNames.workspace_from_destination(row[:request_conversation]) do
      nil -> escape(title)
      workspace -> SlackMarkdown.mentions(title, workspace)
    end
  end

  def generic(title, rows) when is_list(rows) do
    body =
      case rows do
        [] -> "<p class=\"empty\">No durable records in this view.</p>"
        _ -> Enum.map(rows, &generic_row/1)
      end

    ["<section><h2>", escape(title), "</h2>", body, "</section>"]
  end

  def findings(view), do: FindingsPage.render(%{view: view}) |> Safe.to_iodata()

  # Read-only evidence of what the running process assembled: one heading,
  # the settings grouped by the subsystem they belong to with each value's
  # explanation beside it, the code-editing setup guide, and the grant
  # inventory. It never renders a control; product settings are edited in the
  # live sections above it and the deployment environment in the unit file.
  def configuration(%{rows: rows, grants: grants, source: source}) do
    groups =
      rows
      |> Enum.group_by(&configuration_group/1)
      |> Enum.sort_by(fn {{order, _key, _title}, _rows} -> order end)
      |> Enum.map(fn {{_order, key, title}, rows} ->
        [
          "<div class=\"configuration-group\" data-group=\"",
          key,
          "\"><h3>",
          title,
          "</h3>",
          Enum.map(rows, &configuration_setting(&1, source)),
          "</div>"
        ]
      end)

    grant_rows =
      Enum.map(grants, fn grant ->
        [
          [
            escape(grant.kind),
            "<span class=\"row-secondary\">",
            escape(ConfigurationHelp.grant(grant.kind)),
            "</span>"
          ],
          ["<code>", escape(grant.name), "</code>"],
          ["<code>", escape(grant.source), "</code>"]
        ]
      end)

    [
      "<div class=\"configuration-evidence\"><section class=\"configuration-values\"><h2>Effective host configuration</h2><p class=\"section-description\">What the running process assembled from these settings, the deployment environment and the shipped defaults, and what each setting changes. Assembled from <code>",
      escape(source),
      "</code>.</p><div class=\"configuration-change-note\"><strong>How to change these settings</strong><p>This part is read-only evidence. Product settings are edited in the sections above and take effect without a deployment; the deployment environment (database, listeners, credentials) is set in the unit file. Refreshing this page does not change running work.</p><p>Configured means this installation saved a setting, not that its connection or workers are healthy. Running values can lag a save that has not been applied yet. Credentials, URLs, callback values and raw policy documents remain private.</p></div>",
      if(groups == [],
        do: empty_state("No effective settings were published by the running process."),
        else: [
          "<div class=\"configuration-settings\" aria-label=\"Effective values and explanations\">",
          groups,
          "</div>"
        ]
      ),
      "</section>",
      code_editing_setup(),
      "<section class=\"configuration-grants\"><h2>MCP and tool grants</h2><p class=\"section-description\">This is an inventory of configured names, not a live tool-health check. Listing a tool does not grant permission to use it.</p>",
      if(grant_rows == [],
        do: empty_state("No MCP or tool grants are configured."),
        else: data_table(["Grant kind", "Capability or tool", "Source"], grant_rows)
      ),
      "</section><p class=\"muted\">Repository-specific policy topology and serving-worker revisions are shown under <a href=\"/repositories\">Repositories</a>.</p></div>"
    ]
  end

  # Presence flags have bare keys; everything else groups by the prefix of its
  # dotted key, in the order an operator reads a deployment: what runs, then
  # how each part behaves.
  defp configuration_group(%{key: key}) do
    case String.split(key, ".", parts: 2) do
      [_flag] -> {0, "subsystems", "Subsystems"}
      ["runtime", _] -> {1, "runtime", "Runtime"}
      ["admission", _] -> {2, "admission", "Admission"}
      ["work", _] -> {3, "work", "Work execution"}
      ["retention", _] -> {4, "retention", "Cleanup and retention"}
      _ -> {5, "other", "Other settings"}
    end
  end

  defp configuration_setting(row, source) do
    help = ConfigurationHelp.setting(row.key)

    [
      "<section class=\"configuration-setting\" data-setting=\"",
      escape(row.key),
      "\"><div class=\"configuration-setting-value\"><h4>",
      escape(help.title),
      "</h4><code>",
      escape(row.key),
      "</code><p class=\"configuration-value\">",
      escape(ConfigurationHelp.value(row.key, row.value)),
      "</p><span class=\"configuration-raw\">Loaded value: <code>",
      escape(row.value),
      "</code></span></div><div class=\"configuration-setting-help\"><p class=\"configuration-purpose\">",
      escape(help.purpose),
      "</p><p class=\"configuration-behavior\">",
      escape(help.behavior),
      "</p><p class=\"configuration-default\"><strong>Default / requirement:</strong> ",
      escape(help.default),
      "</p>",
      if(row.source != source,
        do: [
          "<p class=\"configuration-provenance\">Loaded from <code>",
          escape(row.source),
          "</code>.</p>"
        ],
        else: []
      ),
      "</div></section>"
    ]
  end

  defp code_editing_setup do
    status =
      if CodeEditingSetup.checkpoint_supported?(),
        do:
          "The running connection supports saving work. This does not prove that a compatible coding worker is online or that its checks can run.",
        else:
          "The running connection does not support saving coding work. Repository-editing tasks cannot start with this setup."

    [
      "<section id=\"code-editing\" class=\"code-editing-setup\"><h2>Set up code editing</h2><p>",
      escape(status),
      "</p><p>The coding service must be able to save a recoverable copy of its files before it can change a repository. An administrator must complete these steps:</p><ol>",
      "<li><strong>Prepare a coding worker.</strong> Use a co:op fleet worker with persistent storage, the intended repository and reviewed execution policy. Install the repository’s build tools inside its coding environment. If the checks require Docker, verify Docker there—not just on the host. Do not grant host Docker access without reviewing that permission.</li>",
      "<li><strong>Connect the worker.</strong> Configure the authenticated worker gateway, then issue a one-time enrollment token with <code>mix responder.coop_worker enroll WORKER_ID WORKSPACE_REF OPERATOR_REF</code> using the release’s database environment. Keep the token private. Configure the worker’s gateway URL, CA, repository, actual policy digests and capabilities, then run <code>coop worker connect --config /etc/coop/worker.json</code>. Its local co:op session service must already be running under the same OS user. These names and paths are examples, not ready-to-run values.</li>",
      "<li><strong>Select the workspace.</strong> In <strong>Settings → Work placement</strong>, select that worker’s exact enrolled workspace, and in <strong>Execution policies</strong> bind the purposes this repository needs to the policies the worker advertises. The change applies to the running host without a deployment. Check that the worker provides the required <code>responder-state</code> capability.</li>",
      "<li><strong>Verify before retrying.</strong> Confirm the worker is connected, eligible for this repository and policy, and can save and restore a disposable workspace. Run a small required check in that environment. Then return to the task and retry it. Changing the configuration alone is not a readiness check.</li>",
      "</ol><p>This page is read-only: it does not enroll workers, change permissions or retry tasks.</p>",
      code_editing_commands(),
      "</section>"
    ]
  end

  defp code_editing_commands do
    """
    <details><summary>Administrator commands and configuration</summary>
    <p>Replace these example paths and names with your reviewed deployment values. Keep the existing service and its files; do not start a duplicate daemon.</p>
    <p>Inspect the existing session service and its real policies:</p>
    <pre><code>coop sessions doctor --socket /var/lib/coop-sessions/control.sock
    coop sessions policies --policies /etc/coop/session-policies.yaml --json</code></pre>
    <p>Enrollment requires the running release’s <code>MIX_ENV=prod</code> and <code>DATABASE_URL</code> environment. The enrollment command does not accept <code>--config</code>. Save only the returned token value in a private file with mode <code>0600</code>; do not put it in chat or command arguments.</p>
    <p>The worker JSON needs the authenticated HTTPS gateway, trusted CA, enrollment-token file, local session socket, actual policy and authority digests, repositories, capabilities and capacity. Its <code>identity_file</code> must initially be absent and its <code>journal_dir</code> persistent and private. Preserve both after enrollment. Use the worker gateway, not the operator control plane, for this connection.</p>
    <p>Select the enrolled workspace in <strong>Settings → Work placement</strong> and bind its purposes in <strong>Execution policies</strong>; both apply to the running host without a deployment. Confirm what is actually running:</p>
    <pre><code>MIX_ENV=prod mix responder.doctor</code></pre>
    <p>It reports the applied revision beside the saved one, so a save that could not be assembled is visible rather than assumed. Finally, verify worker eligibility, workspace save/restore and required build tools before retrying. Do not rotate the gateway’s checkpoint encryption key: existing saved work depends on it.</p>
    </details>
    """
  end

  def usage(snapshot),
    do: UsagePage.render(snapshot)

  def css, do: base_css()

  defp base_css do
    """
    :root{color-scheme:dark;--bg:#080a0d;--panel:#13171c;--panel-raised:#191f26;--text:#f3f4ef;--muted:#95a0ac;--line:#29323c;--accent:#c6ff47;--cyan:#79e8ff;--danger:#ff776d;--warning:#ffc857}
    *{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 85% -10%,#142530 0,transparent 34rem),var(--bg);color:var(--text);font-family:ui-sans-serif,system-ui,-apple-system,sans-serif;line-height:1.5}
    header{position:sticky;top:0;background:#080a0df2;border-bottom:1px solid var(--line);padding:1rem 2rem;z-index:2;backdrop-filter:blur(12px)}.brand{color:var(--accent);font-weight:900;letter-spacing:.02em;text-decoration:none}nav{display:flex;flex-wrap:wrap;gap:.8rem;margin-top:.7rem}nav a,a{color:#c9e7ff}main{max-width:1180px;margin:0 auto;padding:2rem}footer{max-width:1180px;margin:2rem auto;padding:1rem 2rem;color:var(--muted);border-top:1px solid var(--line)}
    h1{font-size:clamp(1.8rem,4vw,2.7rem);letter-spacing:-.035em}h2{margin-top:2rem;letter-spacing:-.02em}.metrics{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:1rem}.metric,section.confirm{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:1rem}.metric strong{display:block;font-size:2rem}.metric span,.muted,.empty{color:var(--muted)}
    table{border-collapse:collapse;width:100%;background:var(--panel)}th,td{border-bottom:1px solid var(--line);padding:.75rem;text-align:left;vertical-align:top}th{color:var(--muted);font-size:.8rem;text-transform:uppercase}dl{display:grid;grid-template-columns:max-content 1fr;gap:.5rem 1rem}dt{color:var(--muted)}dd{margin:0;overflow-wrap:anywhere}
    button,.button{background:var(--accent);border:0;border-radius:7px;color:#0a0b0d;display:inline-block;font:inherit;font-weight:700;padding:.65rem .9rem;text-decoration:none}.danger{background:var(--danger)}.windows{margin:0 0 1rem}.windows a[aria-current=page]{color:var(--accent);font-weight:800}.trend{background:var(--panel);border:1px solid var(--line);border-radius:12px;display:block;max-width:100%;width:100%}.trend rect{fill:var(--accent)}
    code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.9em}.eyebrow{color:var(--accent);font-size:.72rem;font-weight:900;letter-spacing:.16em;margin:0 0 .4rem;text-transform:uppercase}.lab-hero{align-items:center;background:linear-gradient(125deg,#18222b,#101419 70%);border:1px solid #34414d;border-radius:18px;display:flex;gap:2rem;justify-content:space-between;padding:clamp(1.3rem,4vw,2.5rem)}.lab-hero h2{font-size:clamp(1.5rem,3vw,2.35rem);margin:.15rem 0}.lab-hero p{color:#b8c2cc;max-width:68ch}.lab-shell{background:#0d1116;border:1px solid var(--line);border-radius:18px;overflow:hidden}.lab-heading{align-items:flex-start;background:linear-gradient(120deg,#182029,#10151b);border-bottom:1px solid var(--line);display:flex;justify-content:space-between;padding:1.4rem}.lab-heading h2{margin:.1rem 0}.lab-heading p{margin:.2rem 0}.lab-safety-note{background:#142017;border-bottom:1px solid #334d36;color:#c7d6c5;margin:0;padding:.75rem 1.4rem}.lab-safety-note strong{color:var(--accent)}.status-cluster{align-items:flex-end;display:flex;flex-direction:column;gap:.55rem}.status{border:1px solid var(--line);border-radius:999px;font-size:.72rem;font-weight:900;letter-spacing:.08em;padding:.3rem .65rem;text-transform:uppercase}.status.live{border-color:#587425;color:var(--accent)}.status.waiting{border-color:#6f5b2d;color:var(--warning)}.status.blocked{border-color:#7f3a39;color:var(--danger)}.quiet-link{color:var(--muted);font-size:.82rem}.lab-stream{display:grid;grid-template-columns:minmax(0,1fr) 260px;min-height:280px}.messages{display:flex;flex-direction:column;gap:1rem;padding:1.4rem}.message{border:1px solid var(--line);border-radius:14px;max-width:86%;padding:.9rem 1rem}.message.operator{align-self:flex-end;background:#243420;border-color:#3f5d35}.message.integration{align-self:flex-start;background:#171b20;border-color:#5c6570;border-style:dashed;color:#d5dbe1}.message.responder{align-self:flex-start;background:var(--panel-raised);border-color:#344553}.message-head{align-items:center;color:var(--muted);display:flex;font-size:.72rem;gap:.65rem;justify-content:space-between;margin-bottom:.45rem;text-transform:uppercase}.message-body{overflow-wrap:anywhere;white-space:pre-wrap}.message-refs{display:flex;flex-wrap:wrap;gap:.35rem;margin:.65rem 0 0}.message-refs code{background:#0c1014;border-radius:5px;color:var(--cyan);padding:.15rem .35rem}.custody-strip{background:#0a0e12;border-left:1px solid var(--line);padding:1.25rem}.custody-strip strong{color:var(--cyan);font-size:.76rem;letter-spacing:.1em;text-transform:uppercase}.custody-strip ul{list-style:none;margin:1rem 0;padding:0}.custody-strip li{border-top:1px solid var(--line);padding:.7rem 0}.custody-strip li span{color:var(--muted);display:block;font-size:.78rem}.composer{border-top:1px solid var(--line);padding:1.25rem}.composer label{display:block;font-size:.8rem;font-weight:800;margin-bottom:.45rem;text-transform:uppercase}.composer textarea,.composer input[type=file]{background:#090d11;border:1px solid #3a4652;border-radius:10px;color:var(--text);font:inherit;padding:.85rem;width:100%}.composer textarea{resize:vertical}.composer textarea:focus,.composer input[type=file]:focus{border-color:var(--accent);outline:2px solid #c6ff4730}.composer .attachment-label{margin-top:.8rem}.composer-actions{align-items:center;color:var(--muted);display:flex;font-size:.78rem;gap:1rem;justify-content:space-between;margin-top:.8rem}
    .message-reactions{display:flex;gap:.35rem;margin-top:.55rem}.reaction-chip{background:#1c2831;border:1px solid #3b5364;border-radius:999px;color:#d8f6ff;font-family:var(--mono);font-size:.75rem;padding:.2rem .5rem}.message-attachments{display:grid;gap:.55rem;margin-top:.7rem}.attachment-chip{background:#101920;border:1px solid #3b5364;border-radius:8px;color:#d8f6ff;display:flex;flex-wrap:wrap;font-size:.78rem;gap:.45rem;padding:.45rem .6rem}.attachment-chip span{color:var(--muted)}.attachment-download{color:inherit;display:grid;gap:.45rem;text-decoration:none}.attachment-download img{background:#080a0d;border:1px solid var(--line);border-radius:8px;display:block;max-height:280px;max-width:100%;object-fit:contain}.lab-message-controls{align-items:flex-start;border-top:1px solid #3f5d35;display:flex;gap:.55rem;justify-content:flex-end;margin-top:.8rem;padding-top:.65rem}.lab-message-controls details{flex:1}.lab-message-controls summary{cursor:pointer;font-size:.75rem;font-weight:800}.lab-message-controls label{display:grid;font-size:.72rem;gap:.35rem;margin-top:.55rem}.lab-message-controls textarea{background:#090d11;border:1px solid #3a4652;border-radius:8px;color:var(--text);font:inherit;padding:.6rem;resize:vertical;width:100%}.danger-button{border:1px solid #7f3a39;color:#ffb3ad}.message-cards{display:grid;gap:.7rem;margin-top:.85rem}.lab-card{background:#0e1419;border:1px solid #344553;border-left:3px solid var(--cyan);border-radius:10px;padding:.85rem}.lab-card-head{color:var(--cyan);display:flex;font-size:.68rem;font-weight:900;gap:1rem;justify-content:space-between;letter-spacing:.1em;text-transform:uppercase}.lab-card h3{font-size:1rem;margin:.45rem 0}.lab-card p{color:#cbd3da;margin:.35rem 0;white-space:pre-wrap}.lab-card dl{font-size:.78rem;grid-template-columns:max-content minmax(0,1fr);margin:.65rem 0}.choice-list{display:flex;flex-wrap:wrap;gap:.4rem;margin-top:.65rem}.choice-chip{background:#1c2831;border:1px solid #3b5364;border-radius:999px;color:#d8f6ff;font-size:.78rem;padding:.25rem .55rem}
    .lab-reaction-controls{border-top:1px solid #344553;margin-top:.8rem;padding-top:.65rem}.reaction-label{color:var(--muted);display:block;font-size:.7rem;font-weight:800;letter-spacing:.07em;margin-bottom:.45rem;text-transform:uppercase}.quick-reactions,.feedback-reactions{align-items:center;display:flex;flex-wrap:wrap;gap:.35rem}.feedback-reactions{margin-bottom:.45rem}.reaction-form{display:inline}.reaction-form button{background:#1c2831;border:1px solid #3b5364;color:#d8f6ff;font-size:.75rem;padding:.3rem .5rem}.feedback-reaction{align-items:center;background:#142017;border:1px solid #3f5d35;border-radius:999px;display:inline-flex;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.75rem;gap:.25rem;padding-left:.5rem}.feedback-reaction button{border:0;border-left:1px solid #3f5d35;border-radius:0 999px 999px 0;padding:.2rem .4rem}.lab-reaction-controls details{margin-top:.45rem}.lab-reaction-controls summary{cursor:pointer;font-size:.72rem}.lab-reaction-controls label{display:flex;font-size:.72rem;gap:.4rem;margin-top:.4rem}.lab-reaction-controls input[name=emoji]{background:#090d11;border:1px solid #3a4652;border-radius:7px;color:var(--text);font:inherit;padding:.35rem}.danger-button{background:#261312}.lab-card-actions{display:flex;flex-wrap:wrap;gap:.5rem;margin-top:.75rem}.lab-card-actions form{margin:0}.lab-card-actions button,.lab-card-actions .button{font-size:.82rem;padding:.5rem .7rem}.work-view{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:1.2rem}.work-view pre{background:#090d11;border:1px solid var(--line);border-radius:10px;color:#dbe7ef;overflow:auto;padding:1rem;white-space:pre-wrap}.work-view-actions{align-items:center;display:flex;flex-wrap:wrap;gap:.7rem;margin-top:1rem}
    .record-body{background:#090d11;border:1px solid var(--line);border-radius:10px;color:#dbe7ef;overflow:auto;padding:1rem;white-space:pre-wrap}
    .episode-hero{align-items:end;background:linear-gradient(118deg,#172128 0,#0e1217 62%,#17200f 100%);border:1px solid #33404b;border-radius:20px;display:flex;gap:2rem;justify-content:space-between;overflow:hidden;padding:clamp(1.3rem,4vw,2.4rem);position:relative}.episode-hero:after{background:linear-gradient(90deg,transparent,var(--accent));bottom:0;content:"";height:2px;left:0;position:absolute;width:100%}.episode-hero h2{font-size:clamp(1.45rem,3vw,2.3rem);margin:.15rem 0}.episode-ref{color:var(--muted);margin:.7rem 0 0;overflow-wrap:anywhere}.episode-state{border-left:2px solid var(--line);display:grid;min-width:190px;padding:.2rem 0 .2rem 1rem}.episode-state span,.episode-state small{color:var(--muted);font-size:.7rem;font-weight:800;letter-spacing:.08em;text-transform:uppercase}.episode-state strong{font-size:1.25rem;margin:.15rem 0}.episode-state.tone-good{border-color:var(--accent)}.episode-state.tone-warn{border-color:var(--warning)}.episode-state.tone-bad{border-color:var(--danger)}
    .episode-actions{align-items:center;background:#11171c;border:1px solid var(--line);border-radius:14px;display:flex;gap:1rem;justify-content:space-between;margin:1rem 0;padding:.85rem 1rem}.episode-action-copy{display:grid;gap:.1rem}.episode-action-copy strong{font-size:.92rem}.episode-action-copy small{color:var(--muted)}.episode-action-buttons{display:flex;flex-wrap:wrap;gap:.5rem;justify-content:flex-end}.button.secondary{background:#202a32}.button.danger{background:#5c2927}.episode-metrics{display:grid;gap:.65rem;grid-template-columns:repeat(auto-fit,minmax(125px,1fr));margin:1rem 0}.episode-metric{background:#0e1318;border:1px solid var(--line);border-radius:11px;display:grid;min-height:112px;padding:.85rem}.episode-metric>span{color:var(--muted);font-size:.66rem;font-weight:900;letter-spacing:.12em;text-transform:uppercase}.episode-metric strong{align-self:end;font-size:1.3rem;line-height:1.15;margin:.65rem 0 .25rem;overflow-wrap:anywhere}.episode-metric small{color:#89949f}.episode-metric.tone-good{border-top-color:#6c8e2e}.episode-metric.tone-warn{border-top-color:#8d6c25}.episode-metric.tone-bad{border-top-color:#994743}.episode-context{background:#0c1014;border:1px solid var(--line);border-radius:12px;margin:1rem 0;padding:.15rem 1rem}.episode-context dl{font-size:.78rem;grid-template-columns:max-content minmax(0,1fr)}
    .episode-stop{background:linear-gradient(120deg,#2a1717,#151114);border:1px solid #713c3b;border-radius:16px;display:grid;gap:1.1rem;grid-template-columns:46px minmax(0,1fr);margin:1rem 0;padding:1.15rem}.stop-signal{align-items:center;background:var(--danger);border-radius:50%;color:#1b0909;display:flex;font-size:1.35rem;font-weight:950;height:42px;justify-content:center;width:42px}.episode-stop h2{font-size:1.25rem;margin:.1rem 0}.episode-stop p{color:#dbbfbd;margin:.35rem 0}.stop-attempted{border-top:1px solid #563130;margin-top:.8rem;padding-top:.7rem}.stop-attempted>span,.stop-action>span{color:#bf9693;display:block;font-size:.67rem;font-weight:900;letter-spacing:.1em;text-transform:uppercase}.stop-attempted ul{display:flex;flex-wrap:wrap;gap:.4rem;list-style:none;margin:.45rem 0 0;padding:0}.stop-attempted li{background:#321d1e;border:1px solid #603333;border-radius:999px;color:#f0cdca;font-size:.76rem;padding:.18rem .55rem}.stop-action{align-items:center;display:grid;gap:.15rem;grid-template-columns:minmax(0,1fr) auto;margin-top:.85rem}.stop-action span,.stop-action strong{grid-column:1}.stop-action .button{grid-column:2;grid-row:1/3}
    .trace-shell{background:#0b0f13;border:1px solid var(--line);border-radius:18px;margin-top:1.1rem;overflow:hidden}.trace-heading{align-items:flex-start;background:linear-gradient(110deg,#151c23,#0d1115);border-bottom:1px solid var(--line);display:flex;gap:2rem;justify-content:space-between;padding:1.4rem}.trace-heading h2{font-size:1.45rem;margin:.1rem 0}.trace-heading p:last-child{color:var(--muted);margin:.3rem 0;max-width:68ch}.trace-stats{display:flex;gap:.45rem}.trace-stats>span{background:#0a0e12;border:1px solid var(--line);border-radius:8px;color:var(--muted);display:grid;font-size:.62rem;letter-spacing:.08em;min-width:66px;padding:.45rem;text-align:center;text-transform:uppercase}.trace-stats strong{color:var(--text);font-size:1rem}.trace-chapter{padding:0 1.4rem}.trace-chapter+.trace-chapter{border-top:1px solid var(--line)}.chapter-heading{align-items:center;display:grid;gap:1rem;grid-template-columns:42px minmax(0,1fr) auto;padding:1.3rem 0 .8rem}.chapter-number{color:var(--cyan);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.78rem;font-weight:900;letter-spacing:.12em}.chapter-heading h3{font-size:1.15rem;margin:0}.chapter-heading p{color:var(--muted);font-size:.82rem;margin:.15rem 0}.chapter-span{color:var(--muted);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.7rem}
    .trace-rail{padding:0 0 1.25rem 20px;position:relative}.trace-rail:before{background:#33414c;bottom:1.7rem;content:"";left:26px;position:absolute;top:.55rem;width:1px}.trace-step{display:grid;gap:1rem;grid-template-columns:14px minmax(0,1fr);position:relative}.trace-step+.trace-step{margin-top:.7rem}.trace-marker{background:#6f7c87;border:3px solid #0b0f13;border-radius:50%;height:13px;margin-top:1.1rem;position:relative;width:13px;z-index:1}.trace-step.tone-good .trace-marker{background:var(--accent)}.trace-step.tone-warn .trace-marker{background:var(--warning)}.trace-step.tone-bad .trace-marker{background:var(--danger)}.trace-card{background:#11171d;border:1px solid #293640;border-radius:11px;padding:.85rem 1rem}.trace-step.tone-good .trace-card{border-left-color:#6c8e2e}.trace-step.tone-warn .trace-card{border-left-color:#8d6c25}.trace-step.tone-bad .trace-card{border-left-color:#994743}.trace-card-head{align-items:center;display:flex;gap:1rem;justify-content:space-between}.trace-labels,.trace-time{align-items:center;display:flex;flex-wrap:wrap;gap:.4rem}.trace-stage,.trace-state{border:1px solid #3b4853;border-radius:999px;color:#aab6c0;font-size:.62rem;font-weight:900;letter-spacing:.08em;padding:.15rem .45rem;text-transform:uppercase}.trace-state{border-color:#365364;color:var(--cyan)}.trace-time{color:#788590;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.66rem}.trace-card h4{font-size:1rem;margin:.55rem 0 .15rem}.trace-card h4 a{color:var(--text)}.trace-card>p{color:#bdc6ce;margin:.2rem 0}.trace-byline{color:#7f8c97;font-size:.68rem;font-weight:800;letter-spacing:.08em;margin-top:.5rem;text-transform:uppercase}.trace-details{border-top:1px solid #293640;margin-top:.7rem;padding-top:.55rem}.trace-details summary{color:#9facb7;cursor:pointer;font-size:.7rem;font-weight:800;letter-spacing:.05em}.trace-details dl{font-size:.74rem;grid-template-columns:minmax(100px,max-content) minmax(0,1fr);margin:.65rem 0 .15rem}.trace-details dd{color:#d2dae1;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}.trace-empty{color:var(--muted);padding:1.4rem}.tone-good .trace-state{border-color:#536d29;color:var(--accent)}.tone-warn .trace-state{border-color:#715a2a;color:var(--warning)}.tone-bad .trace-state{border-color:#743a39;color:var(--danger)}
    @media(max-width:760px){header,main{padding-left:1rem;padding-right:1rem}.lab-hero,.lab-heading,.episode-hero,.episode-actions,.trace-heading{align-items:stretch;flex-direction:column}.episode-action-buttons{justify-content:flex-start}.lab-stream{grid-template-columns:1fr}.custody-strip{border-left:0;border-top:1px solid var(--line)}.message{max-width:96%}.composer-actions{align-items:stretch;flex-direction:column}.episode-state{min-width:0}.trace-stats{align-self:stretch}.trace-stats>span{flex:1}.chapter-heading{align-items:start;grid-template-columns:32px minmax(0,1fr)}.chapter-span{grid-column:2}.trace-chapter{padding:0 .85rem}.trace-rail{padding-left:10px}.trace-rail:before{left:16px}.trace-card-head{align-items:flex-start;flex-direction:column}.stop-action{grid-template-columns:1fr}.stop-action .button{grid-column:1;grid-row:auto;margin-top:.6rem;text-align:center}}
    """
  end

  defp attention_list([]), do: "<p class=\"empty\">Nothing needs attention.</p>"

  defp attention_list(rows) do
    [
      "<ul>",
      Enum.map(rows, fn row ->
        ["<li><strong>", escape(row.title), "</strong> — ", escape(row.kind), "</li>"]
      end),
      "</ul>"
    ]
  end

  @doc false
  def lab_message_extras(message) do
    [
      "<div class=\"message-attachments\">",
      Enum.map(Map.get(message, :attachments, []), &lab_attachment/1),
      "</div>",
      lab_generated_files(Map.get(message, :generated_files, [])),
      "<div class=\"message-reactions\">",
      Enum.map(Map.get(message, :reactions, []), &lab_reaction/1),
      "</div>",
      "<div class=\"message-cards\">",
      Enum.map(Map.get(message, :cards, []), &lab_card/1),
      "</div>",
      lab_feedback_reaction_controls(message),
      lab_message_controls(message)
    ]
  end

  defp lab_generated_files([]), do: ""

  defp lab_generated_files(files) do
    [
      "<section class=\"lab-generated-files\"><h4>Generated files</h4><div class=\"message-attachments\">",
      Enum.map(files, &lab_attachment/1),
      "</div></section>"
    ]
  end

  defp lab_message(message) do
    refs =
      (message.record_refs ++ message.artifact_refs)
      |> Enum.map(&["<code>", escape(&1), "</code>"])

    cards = Map.get(message, :cards, []) |> Enum.map(&lab_card/1)
    reactions = Map.get(message, :reactions, []) |> Enum.map(&lab_reaction/1)
    attachments = Map.get(message, :attachments, []) |> Enum.map(&lab_attachment/1)
    message_controls = lab_message_controls(message)
    reaction_controls = lab_feedback_reaction_controls(message)

    [
      "<article class=\"message ",
      lab_actor_class(message.actor),
      "\"><div class=\"message-head\"><strong>",
      lab_actor_label(message.actor),
      "</strong><span>",
      escape(lab_message_status(message)),
      " · ",
      timestamp(message.occurred_at),
      "</span></div><div class=\"message-body\">",
      escape(message.text),
      "</div>",
      if(reactions == [],
        do: "",
        else: ["<div class=\"message-reactions\">", reactions, "</div>"]
      ),
      if(attachments == [],
        do: "",
        else: ["<div class=\"message-attachments\">", attachments, "</div>"]
      ),
      if(cards == [], do: "", else: ["<div class=\"message-cards\">", cards, "</div>"]),
      if(refs == [], do: "", else: ["<div class=\"message-refs\">", refs, "</div>"]),
      reaction_controls,
      message_controls,
      "</article>"
    ]
  end

  defp lab_actor_class(:operator), do: "operator"
  defp lab_actor_class(:integration), do: "integration"
  defp lab_actor_class(_actor), do: "responder"

  defp lab_actor_label(:operator), do: "You"
  defp lab_actor_label(:integration), do: "Integration"
  defp lab_actor_label(_actor), do: "Responder"

  defp lab_message_status(%{event_kind: :edit, status: status}), do: "#{status} · edited"
  defp lab_message_status(%{event_kind: :delete, status: status}), do: "#{status} · deleted"
  defp lab_message_status(%{status: status}), do: to_string(status)

  defp lab_admission_progress(items) do
    Enum.map(items, fn item ->
      [
        "<article class=\"lab-admission-progress\"><header><strong>",
        escape(item.phase),
        "</strong><span>",
        duration(item.elapsed_ms),
        " since receipt</span></header><p>",
        escape(item.title),
        "</p><small>",
        escape(item.target || "Execution target not yet observed"),
        " · execution ",
        escape(item.generation),
        " · ",
        escape(item.claims),
        " lease claims (not model calls)</small><p><a href=\"",
        escape(item.href),
        "\">Inspect request and observed progress →</a></p></article>"
      ]
    end)
  end

  defp lab_message_controls(%{
         message_controls: %{
           delete: %{path: delete_path, token: delete_token},
           edit: %{path: edit_path, token: edit_token}
         },
         text: text
       }) do
    [
      "<div class=\"lab-message-controls\"><details><summary>Edit</summary>",
      "<form method=\"post\" action=\"",
      escape(edit_path),
      "\"><input type=\"hidden\" name=\"_token\" value=\"",
      escape(edit_token),
      "\"><label>Edit message<textarea name=\"message\" maxlength=\"20000\" rows=\"3\">",
      escape(text),
      "</textarea></label><button type=\"submit\">Save edit</button></form></details>",
      "<form method=\"post\" action=\"",
      escape(delete_path),
      "\"><input type=\"hidden\" name=\"_token\" value=\"",
      escape(delete_token),
      "\"><button class=\"danger-button\" type=\"submit\">Delete</button></form></div>"
    ]
  end

  defp lab_message_controls(_message), do: ""

  defp lab_feedback_reaction_controls(%{
         feedback_reactions: reactions,
         reaction_controls: %{path: path, token: token}
       })
       when is_list(reactions) and is_binary(path) and is_binary(token) do
    existing =
      Enum.map(reactions, fn reaction ->
        [
          "<span class=\"feedback-reaction\" title=\"Reaction from ",
          escape(reaction.actor_ref),
          "\">:",
          escape(reaction.emoji_name),
          ":",
          lab_feedback_reaction_form(path, token, :remove, reaction.emoji_name, "Remove"),
          "</span>"
        ]
      end)

    quick =
      Enum.map(
        [{"+1", "👍"}, {"heart", "❤️"}, {"eyes", "👀"}, {"tada", "🎉"}, {"rocket", "🚀"}],
        fn {emoji_name, label} ->
          lab_feedback_reaction_form(path, token, :add, emoji_name, label)
        end
      )

    [
      "<div class=\"lab-reaction-controls\"><span class=\"reaction-label\">React to this reply</span>",
      if(existing == [],
        do: "",
        else: ["<div class=\"feedback-reactions\">", existing, "</div>"]
      ),
      "<div class=\"quick-reactions\">",
      quick,
      "<details><summary>Custom emoji</summary><form method=\"post\" action=\"",
      escape(path),
      "\"><input type=\"hidden\" name=\"_token\" value=\"",
      escape(token),
      "\"><input type=\"hidden\" name=\"action\" value=\"add\"><label>Slack emoji name<input name=\"emoji\" maxlength=\"100\" pattern=\"[a-z0-9_+\\-]+\" required></label><button type=\"submit\">Add</button></form></details></div></div>"
    ]
  end

  defp lab_feedback_reaction_controls(_message), do: ""

  defp lab_feedback_reaction_form(path, token, action, emoji_name, label) do
    [
      "<form class=\"reaction-form\" method=\"post\" action=\"",
      escape(path),
      "\"><input type=\"hidden\" name=\"_token\" value=\"",
      escape(token),
      "\"><input type=\"hidden\" name=\"action\" value=\"",
      escape(action),
      "\"><input type=\"hidden\" name=\"emoji\" value=\"",
      escape(emoji_name),
      "\"><button type=\"submit\" aria-label=\"",
      escape("#{label} :#{emoji_name}: reaction"),
      "\">",
      escape(label),
      "</button></form>"
    ]
  end

  defp lab_reaction(reaction) do
    [
      "<span class=\"reaction-chip\" data-reaction-status=\"",
      escape(reaction.status),
      "\" title=\"Responder reaction · ",
      escape(reaction.status),
      "\">:",
      escape(reaction.emoji_name),
      ":</span>"
    ]
  end

  defp lab_attachment(attachment) do
    details =
      case {attachment.media_type, attachment.bytes} do
        {media_type, bytes} when is_binary(media_type) and is_integer(bytes) ->
          [escape(media_type), " · ", integer(bytes), " bytes"]

        _unavailable ->
          escape(attachment.status)
      end

    chip = [
      "<span class=\"attachment-chip\"><strong>",
      escape(attachment.name),
      "</strong><span>",
      details,
      "</span></span>"
    ]

    case Map.get(attachment, :path) do
      path when is_binary(path) ->
        preview =
          if attachment.media_type in ["image/png", "image/jpeg", "image/webp", "image/gif"] do
            [
              "<img src=\"",
              escape(path),
              "\" alt=\"Generated attachment: ",
              escape(attachment.name),
              "\" loading=\"lazy\">"
            ]
          else
            ""
          end

        ["<a class=\"attachment-download\" href=\"", escape(path), "\">", preview, chip, "</a>"]

      _no_path ->
        chip
    end
  end

  defp lab_card(card) do
    details =
      Enum.map(card.details, fn {label, value} ->
        ["<dt>", escape(label), "</dt><dd>", escape(value), "</dd>"]
      end)

    controls = Map.get(card, :controls, []) |> Enum.map(&lab_card_control/1)

    choices =
      if Enum.any?(Map.get(card, :controls, []), &is_integer(&1.choice_index)) do
        []
      else
        Enum.map(card.choices, fn choice ->
          ["<span class=\"choice-chip\">", escape(choice), "</span>"]
        end)
      end

    [
      "<section class=\"lab-card\" data-record-kind=\"",
      escape(card.kind),
      "\"><div class=\"lab-card-head\"><span>",
      escape(card.label),
      "</span>",
      if(Card.display_status(card),
        do: ["<span>", escape(Card.display_status(card)), "</span>"],
        else: ""
      ),
      "</div><h3>",
      escape(card.title),
      "</h3>",
      if(card.summary, do: ["<p>", escape(card.summary), "</p>"], else: ""),
      if(card[:wait_warning],
        do: [
          "<p class=\"action-error\"><strong>Current scheduling status:</strong> ",
          escape(card.wait_warning),
          "</p>"
        ],
        else: ""
      ),
      if(details == [], do: "", else: ["<dl>", details, "</dl>"]),
      if(choices == [], do: "", else: ["<div class=\"choice-list\">", choices, "</div>"]),
      if(controls == [],
        do: "",
        else: ["<div class=\"lab-card-actions\">", controls, "</div>"]
      ),
      if(card.url,
        do: [
          "<a class=\"quiet-link\" href=\"",
          escape(card.url),
          "\" rel=\"noreferrer\">Open exact approval</a>"
        ],
        else: ""
      ),
      "</section>"
    ]
  end

  defp lab_card_control(control) do
    if Map.get(control, :method, :post) == :get do
      ["<a class=\"button\" href=\"", escape(control.path), "\">", escape(control.label), "</a>"]
    else
      [
        "<form method=\"post\" action=\"",
        escape(control.path),
        "\"><input type=\"hidden\" name=\"_token\" value=\"",
        escape(control.token),
        "\">",
        if(is_integer(control.choice_index),
          do: [
            "<input type=\"hidden\" name=\"choice_index\" value=\"",
            integer(control.choice_index),
            "\">"
          ],
          else: ""
        ),
        if(is_binary(Map.get(control, :publication_ref)),
          do: [
            "<input type=\"hidden\" name=\"publication_ref\" value=\"",
            escape(control.publication_ref),
            "\">"
          ],
          else: ""
        ),
        "<button type=\"submit\">",
        escape(control.label),
        "</button></form>"
      ]
    end
  end

  defp status_badge(%{blocked: true}),
    do: "<span class=\"status blocked\">Needs attention</span>"

  defp status_badge(%{live: true, pending: pending}),
    do: ["<span class=\"status live\">Working · ", integer(pending), " queued</span>"]

  defp status_badge(%{episodes: [%{state: state} | _rest]})
       when state in [:waiting_for_input, :waiting_for_event],
       do: ["<span class=\"status waiting\">", escape(state), "</span>"]

  defp status_badge(_snapshot), do: "<span class=\"status\">Settled</span>"

  defp failure_episode(row) do
    case Map.get(row, :episode_ref) do
      nil ->
        "Before admission"

      ref ->
        [
          "<a title=\"",
          escape(ref),
          "\" href=\"/timeline/",
          segment(ref),
          "\">",
          escape(Map.get(row, :request_title) || "Open request"),
          " →</a>"
        ]
    end
  end

  # The shared toolbar: search on Enter, a status dropdown that applies on
  # change, and a clear link once anything is filtered. The page's title and
  # description are the shell's; a list body starts here.
  defp search_form(path, placeholder, params, statuses \\ [], status_label \\ &Components.label/1) do
    params = UsageProjection.link_params(params)
    status = params["status"]

    selects =
      if statuses == [],
        do: [],
        else: [
          %{
            id: "operator-status",
            name: "status",
            label: "Status",
            value: if(status in statuses, do: status, else: ""),
            options: [{"", "All statuses"} | Enum.map(statuses, &{&1, status_label.(&1)})]
          }
        ]

    %{
      __changed__: nil,
      id: "operator-search",
      path: path,
      label: "Filter this list",
      placeholder: placeholder,
      query: params["q"] || "",
      filtered: params["q"] not in [nil, ""] or status in statuses,
      selects: selects
    }
    |> Components.filter_toolbar()
    |> Safe.to_iodata()
  end

  # Whether the toolbar is narrowing the list. An empty page must first say
  # which it is: nothing matches, or nothing exists.
  defp filtered?(params, statuses) do
    params = UsageProjection.link_params(params)
    params["q"] not in [nil, ""] or params["status"] in statuses
  end

  # The shared help disclosure and quiet count, rendered through the same
  # components the HEEx pages use, so there is one markup contract to style.
  defp page_help(id, label, body) do
    body = IO.iodata_to_binary(body)

    %{
      __changed__: nil,
      id: id,
      label: label,
      inner_block: [
        %{__slot__: :inner_block, inner_block: fn _, _ -> Phoenix.HTML.raw(body) end}
      ]
    }
    |> Components.page_help()
    |> Safe.to_iodata()
  end

  defp result_count(count, one, many) do
    %{__changed__: nil, count: count, one: one, many: many}
    |> Components.result_count()
    |> Safe.to_iodata()
  end

  defp empty_state(text), do: ["<p class=\"empty-state\">", escape(text), "</p>"]

  # Dot plus word: the state reads without relying on colour.
  defp dot_status(label, tone),
    do: [
      "<span class=\"ui-status status-",
      tone,
      "\"><i aria-hidden=\"true\"></i>",
      escape(label),
      "</span>"
    ]

  # A comparison table whose every cell names its column, so a narrow screen
  # can stack a row into label/value pairs without hiding the row's identity
  # (its first column) or its action. A column is a heading, or {class,
  # heading} when its header and cells share an alignment ("row-number",
  # "row-action"). A row is a list of cells (iodata); {:details, iodata} is a
  # full-width row of details on demand belonging to the row above it.
  defp data_table(columns, rows) do
    columns = Enum.map(columns, &data_column/1)
    span = Integer.to_string(length(columns))

    [
      "<table class=\"data-table\"><thead><tr>",
      Enum.map(columns, fn {class, heading} ->
        ["<th scope=\"col\"", class_attribute([class]), ">", escape(heading), "</th>"]
      end),
      "</tr></thead><tbody>",
      Enum.map(rows, &data_row(&1, columns, span)),
      "</tbody></table>"
    ]
  end

  defp data_column({class, heading}) when is_binary(class), do: {class, heading}
  defp data_column(heading), do: {nil, heading}

  defp data_row({:details, body}, _columns, span),
    do: ["<tr class=\"row-details\"><td colspan=\"", span, "\">", body, "</td></tr>"]

  defp data_row(cells, columns, _span) do
    cells =
      cells
      |> Enum.zip(columns)
      |> Enum.with_index()
      |> Enum.map(fn {{body, {class, heading}}, index} ->
        # The value wrapper is what a stacked row places beside the label.
        [
          "<td data-label=\"",
          escape(heading),
          "\"",
          class_attribute([if(index == 0, do: "row-identity"), class]),
          "><div class=\"cell-value\">",
          body,
          "</div></td>"
        ]
      end)

    ["<tr>", cells, "</tr>"]
  end

  defp class_attribute(classes) do
    case Enum.reject(classes, &is_nil/1) do
      [] -> []
      classes -> [" class=\"", Enum.join(classes, " "), "\""]
    end
  end

  defp recovery_label("delivery"), do: "Retry delivery"
  defp recovery_label("admission"), do: "Retry routing"
  defp recovery_label("emisar"), do: "Resume approval checks"
  defp recovery_label("slack_interaction"), do: "Refresh Slack message"
  defp recovery_label("slack_incident"), do: "Resume room setup"
  defp recovery_label("retention"), do: "Resume cleanup"
  defp recovery_label(_), do: "Retry failed step"

  defp failure_kind("retention"), do: "Working-copy cleanup stopped"
  defp failure_kind("delivery"), do: "Reply could not be delivered"
  defp failure_kind("admission"), do: "Message routing stopped"
  defp failure_kind("work"), do: "Model work stopped"
  defp failure_kind("slack_incident"), do: "Incident room setup stopped"
  defp failure_kind("slack_interaction"), do: "Slack message update stopped"
  defp failure_kind("emisar"), do: "Approval check stopped"
  defp failure_kind("publication"), do: "Publishing stopped"
  defp failure_kind(value), do: String.capitalize(String.replace(value, "_", " "))

  defp failure_cause("coop_error"),
    do: "The worker could not finish this step. Inspect the saved error before retrying."

  defp failure_cause("coop_unavailable"),
    do: "The worker could not be reached. Check its connection, then retry."

  defp failure_cause(value),
    do: to_string(value) |> String.replace("_", " ") |> String.capitalize()

  defp channel_label(_workspace_ref, nil), do: "Channel not created yet"

  defp channel_label(workspace_ref, channel_ref),
    do: SlackNames.name(workspace_ref, channel_ref)

  defp workspace_status(:active), do: {"In use", "active"}
  defp workspace_status(:grace), do: {"Kept for follow-up", "quiet"}
  defp workspace_status(:retained), do: {"Changes preserved", "quiet"}
  defp workspace_status(:discarded), do: {"Removed safely", "done"}
  defp workspace_status(:blocked), do: {"Cleanup needs attention", "attention"}
  defp workspace_status(_), do: {"Cleanup in progress", "active"}

  defp workspace_reason(%{status: :discarded}),
    do: "Working copy removed; request history remains available."

  defp workspace_reason(%{status: :active}),
    do: "Available to the current request and its follow-ups."

  defp workspace_reason(%{status: :grace}),
    do: "Kept temporarily so a follow-up can reuse the same checkout."

  defp workspace_reason(%{summary: "unpublished_unmerged"}),
    do: "Unmerged commits are being kept safe."

  defp workspace_reason(%{summary: "dirty"}), do: "Uncommitted changes are being kept safe."
  defp workspace_reason(%{status: :retained}), do: "Changes are preserved until cleanup is safe."
  defp workspace_reason(%{status: :blocked, summary: value}), do: failure_cause(value)
  defp workspace_reason(_), do: "Automatic cleanup is pending."

  defp repository_revision(nil), do: "No revision recorded yet"

  # The short commit with the full one a hover or the details away; the
  # snapshot caveat lives in the details beneath the row.
  defp repository_revision(freshness),
    do: [
      "<code title=\"",
      escape(freshness.resolved_revision),
      "\">",
      escape(String.slice(freshness.resolved_revision || "unknown", 0, 8)),
      "</code><span class=\"row-secondary\">fetched ",
      readable_time(freshness.fetched_at),
      "</span>"
    ]

  defp channel_kind(%{incident_room: true}), do: "incident room"
  defp channel_kind(%{channel_ref: "D" <> _rest}), do: "direct message"
  defp channel_kind(_item), do: "shared channel"

  defp episode_link(nil), do: "—"

  defp episode_link(ref) do
    IO.iodata_to_binary([
      "<a href=\"/timeline/",
      segment(ref),
      "\"><code>",
      escape(ref),
      "</code></a>"
    ])
  end

  defp publication_detail(nil),
    do: "<p class=\"empty\">Nothing was published from this incident.</p>"

  defp publication_detail(publication) do
    definition_list([
      {"Reference", publication.ref},
      {"Status", publication.status},
      {"Repository", publication.repository},
      {"Branch", publication.branch_ref || "not created"},
      {"Commit", publication.commit_sha || "not created"},
      {"Pull request", publication.pr_number || "not opened"},
      {"Pull request URL", publication.pr_url || "not opened"},
      {"Last failure", publication.last_error || "none"},
      {"Updated", publication.updated_at}
    ])
  end

  defp destination(schedule) do
    base = "#{schedule.destination_transport}:#{schedule.destination_conversation_ref}"

    if schedule.destination_thread_ref,
      do: "#{base} / #{schedule.destination_thread_ref}",
      else: base
  end

  defp occurrence_failure(occurrence) do
    [Map.get(occurrence, :failure_code), Map.get(occurrence, :failure_detail)]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> "none"
      parts -> Enum.join(parts, " / ")
    end
  end

  defp policy_summary(nil), do: "observed only"

  defp policy_summary(configured) do
    [
      configured[:contributor_policy] && "contributor #{configured.contributor_policy}",
      configured[:schedule_policy] && "schedule #{configured.schedule_policy}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> case do
      "" -> "configured"
      value -> value
    end
  end

  defp freshness_detail(nil) do
    "<p class=\"empty\">No frozen freshness-v2 receipt is retained for this repository.</p>"
  end

  defp freshness_detail(freshness) do
    definition_list([
      {"Owner", "Coop"},
      {"Version", freshness.version},
      {"Requested revision", freshness.requested_revision},
      {"Resolved revision", freshness.resolved_revision},
      {"Workspace base", freshness.workspace_base_revision || "not applicable"},
      {"Remote identity", freshness.remote_identity},
      {"Fetched", freshness.fetched_at},
      {"Stale-base status", freshness.stale_base_status},
      {"Stale-base revision", freshness.stale_base_revision || "none"},
      {"Frozen into Work", freshness.recorded_at}
    ])
  end

  defp worker_list([]),
    do:
      empty_state(
        "No fleet worker is reporting this repository here. A configured local development worker is not listed in the fleet."
      )

  defp worker_list(workers) do
    rows =
      Enum.map(workers, fn worker ->
        [
          ["<code>", escape(worker.worker_ref), "</code>"],
          escape(Components.label(worker.state)),
          ["<code>", escape(worker.revision || "unrecorded"), "</code>"],
          if(worker.last_seen_at, do: readable_time(worker.last_seen_at), else: "Never")
        ]
      end)

    data_table(["Worker", "State", "Advertised revision", "Last seen"], rows)
  end

  defp definition_list(rows) do
    [
      "<dl>",
      Enum.map(rows, fn {label, value} ->
        ["<dt>", escape(label), "</dt><dd>", value(value), "</dd>"]
      end),
      "</dl>"
    ]
  end

  defp table(_headings, []), do: "<p class=\"empty\">No durable records.</p>"

  defp table(headings, rows) do
    [
      "<div class=\"table-wrap\"><table><thead><tr>",
      Enum.map(headings, &["<th>", escape(&1), "</th>"]),
      "</tr></thead><tbody>",
      rows,
      "</tbody></table></div>"
    ]
  end

  defp generic_row(row) when is_map(row) do
    safe =
      Map.take(row, [:kind, :ref, :state, :status, :summary, :title, :updated_at, :value, :key])

    [
      "<article class=\"metric\"><dl>",
      Enum.map(safe, fn {key, value} ->
        ["<dt>", escape(key), "</dt><dd>", value(value), "</dd>"]
      end),
      "</dl></article>"
    ]
  end

  defp generic_row(_row), do: ""

  defp value({:safe, value}), do: value
  defp value(%DateTime{} = value), do: timestamp(value)
  defp value(value), do: escape(value)

  defp timestamp(%DateTime{} = value), do: escape(DateTime.to_iso8601(value))
  defp timestamp(nil), do: "—"
  defp timestamp(value), do: escape(value)

  defp readable_time(%DateTime{} = value),
    do: [
      "<time datetime=\"",
      DateTime.to_iso8601(value),
      "\" title=\"",
      DateTime.to_iso8601(value),
      "\">",
      escape(Components.timestamp(value)),
      "</time>"
    ]

  defp readable_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _} -> readable_time(time)
      _ -> escape(value)
    end
  end

  defp readable_time(nil), do: "Time not recorded"

  defp segment(value), do: value |> to_string() |> URI.encode(&URI.char_unreserved?/1)

  defp duration(nil), do: "unmeasured"

  defp duration(milliseconds),
    do: :erlang.float_to_binary(milliseconds / 1_000, decimals: 2) <> " s"

  defp integer(value) when is_integer(value), do: Integer.to_string(value)
  defp integer(value), do: to_string(value)

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
