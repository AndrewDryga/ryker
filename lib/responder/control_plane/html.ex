defmodule Responder.ControlPlane.HTML do
  @moduledoc false

  @nav [
    {"Overview", "/"},
    {"Conversation Lab", "/lab"},
    {"Episodes", "/episodes"},
    {"Incidents", "/incidents"},
    {"Schedules", "/schedules"},
    {"Channels", "/channels"},
    {"Repositories", "/repositories"},
    {"Failures", "/failures"},
    {"Workspaces", "/workspaces"},
    {"Decisions", "/decisions"},
    {"Findings", "/findings"},
    {"Audit", "/audit"},
    {"Memory", "/memory"},
    {"Model calibration", "/calibration"},
    {"Usage", "/usage"},
    {"Configuration", "/configuration"},
    {"Test journeys", "/manual-tests"}
  ]

  @spec page(String.t(), iodata()) :: binary()
  def page(title, body) do
    IO.iodata_to_binary([
      "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">",
      "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">",
      "<title>",
      escape(title),
      " · Responder</title><link rel=\"stylesheet\" href=\"/static/app.css\"></head><body>",
      "<header><a class=\"brand\" href=\"/\">Responder control plane</a>",
      "<nav>",
      Enum.map(@nav, fn {label, href} ->
        ["<a href=\"", href, "\">", escape(label), "</a>"]
      end),
      "</nav></header><main><h1>",
      escape(title),
      "</h1>",
      body,
      "</main><footer>Local, durable, and offline. No external assets.</footer></body></html>"
    ])
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
          "<tr><td><a href=\"/lab/",
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
      "<a class=\"button\" href=\"/lab/new\">Start conversation</a></section>",
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
          "<li><a href=\"/episodes/",
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
      "<section class=\"lab-shell\"><div class=\"lab-heading\"><div><p class=\"eyebrow\">Conversation Lab</p><h2>Local model conversation</h2>",
      "<p><code>",
      escape(snapshot.conversation_id),
      "</code></p></div><div class=\"status-cluster\" data-lab-status aria-live=\"polite\">",
      status_badge(snapshot),
      "<a class=\"quiet-link\" href=\"/lab/",
      segment(snapshot.conversation_id),
      "\">Refresh</a></div></div>",
      "<p class=\"lab-safety-note\"><strong>Same conversational product as Slack.</strong> Messages, attachments, generated images, state and Emisar tools, questions, waits, tasks, local incidents, publication cards, confirmation controls, reactions, and additional posts use the same durable runtime. Slack-owned API effects are emulated and labelled inside this Lab; repository and Emisar authority still follows the configured Work policy.</p>",
      "<div class=\"lab-stream\" data-lab-stream data-live=\"",
      if(snapshot.live, do: "true", else: "false"),
      "\" aria-live=\"polite\"><div class=\"messages\">",
      messages,
      "</div><aside class=\"custody-strip\"><strong>Durable custody</strong>",
      if(episodes == [],
        do: "<p>Awaiting admission.</p>",
        else: ["<ul>", episodes, "</ul>"]
      ),
      "</aside></div>",
      "<form class=\"composer\" method=\"post\" enctype=\"multipart/form-data\" action=\"/lab/",
      segment(snapshot.conversation_id),
      "/messages\"><input type=\"hidden\" name=\"_token\" value=\"",
      escape(csrf_token),
      "\"><label for=\"lab-message\">Message</label>",
      "<textarea id=\"lab-message\" name=\"message\" maxlength=\"20000\" data-max-bytes=\"20000\" rows=\"5\" placeholder=\"Ask Responder to investigate, explain, remember, schedule, or continue work…\"></textarea>",
      "<label class=\"attachment-label\" for=\"lab-attachments\">Attachments</label>",
      "<input class=\"attachment-input\" id=\"lab-attachments\" name=\"attachments[]\" type=\"file\" multiple accept=\"image/png,image/jpeg,image/webp,image/gif,text/plain,text/markdown,text/csv,application/json,application/yaml,application/x-yaml,application/pdf\">",
      "<div class=\"composer-actions\"><span>Message or up to 2 files · 8 MiB total · durable on submit</span><button type=\"submit\">Send through Responder</button></div></form></section>",
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

  def manual_tests(configuration) do
    enabled = Map.new(configuration, &{&1.key, &1.value == "enabled"})

    [
      "<section class=\"journey-intro\"><p class=\"eyebrow\">Operator qualification</p>",
      "<h2>Prove behavior at the user boundary</h2><p>Run these after deterministic gates. Use disposable channels, repositories, and records; verify the durable episode after every visible effect.</p></section>",
      "<div class=\"journey-grid\">",
      journey(
        "01",
        "Conversation Lab",
        enabled["control_plane"],
        [
          "Start a new local conversation and ask for a concise answer.",
          "Send a follow-up that depends on the first answer; confirm one conversation and continued episode lineage.",
          "Ask a material question that requires input; answer it here and confirm the same task session resumes.",
          "Upload a bounded text file and image; verify exact previews, then ask for one generated image.",
          "List, search, and read messages and durable files across completed episode boundaries in this virtual workspace.",
          "React locally and confirm one additional post without sending Slack traffic.",
          "Exercise task, local-incident, memory, schedule, automation, governed-action, and publication cards through their host-owned controls.",
          "Confirm a harmless task, inspect its exact diff/timeline/evidence/handoff, and exercise readiness, explicit draft publication, and delivery check.",
          "Confirm a local incident and inspect its evidence-backed postmortem without creating a Slack room.",
          "Restart Responder while work is pending; refresh and confirm custody resumes from PostgreSQL without a duplicate reply."
        ],
        "/lab/new"
      ),
      journey(
        "02",
        "Slack threads, cards, and emoji",
        enabled["slack"],
        [
          "Mention Responder in an approved test channel; confirm the reply stays in the exact thread.",
          "Request a task: confirm the host-owned offer card, then verify status, progress repaint, Stop, and idempotent button retries.",
          "React with configured Unicode and custom emoji; confirm one normalized reaction input and no bot-loop echo.",
          "Upload a bounded attachment and create an incident room; verify authenticated fetch, audience, topic, bookmarks, and cleanup."
        ]
      ),
      journey(
        "03",
        "GitHub comments, reviews, and reactions",
        enabled["github"],
        [
          "Comment on a disposable issue and verify the reply binds to that issue, installation, and repository.",
          "Request a PR review; verify review summaries and inline review-thread replies use their exact targets.",
          "Add +1, -1, laugh, confused, heart, hooray, rocket, and eyes reactions; confirm normalized emoji semantics and idempotent delivery.",
          "Edit and delete source comments; verify stable item revisions cannot move work to another episode."
        ]
      ),
      journey(
        "04",
        "Universal signed webhook",
        enabled["webhooks"],
        [
          "Send an authenticated arbitrary JSON object with a unique occurrence ID and stable item ID.",
          "Confirm the model reports observed fields without inventing vendor meaning.",
          "Replay the exact request and then a changed body under the same ID; expect duplicate then conflict.",
          "Send revision 2 for the stable item and verify ownership remains with its original episode."
        ],
        nil,
        webhook_example()
      ),
      journey(
        "05",
        "State tools and long-running work",
        enabled["state_tools"],
        [
          "Create evidence, progress, a required goal, and a task offer; confirm typed records are visible exactly once.",
          "Offer a memory and schedule, confirm them through their host UI, then verify recurrence and expiration.",
          "Exercise input and event waits; confirm no worker lease is held while waiting and only the exact trigger resumes.",
          "Force one semantic correction and one lost response; confirm same-turn repair and exactly-once delivery."
        ]
      ),
      journey(
        "06",
        "Recovery and retention",
        enabled["retention"],
        [
          "Restart after frozen submit, accepted result, and delivery send; reconcile each exact operation without duplication.",
          "Stop running work and verify the exact remote turn is fenced before local cancellation settles.",
          "Complete work with clean, dirty, and unmerged workspaces; verify close/discard/retain decisions and rearm controls.",
          "Restore a database dump into a disposable database and boot the same release against it."
        ]
      ),
      journey(
        "07",
        "Local operator workbench",
        enabled["control_plane"],
        [
          "Open Incidents and verify a room links to its source and investigation episodes, lifecycle observations, evidence records, and sanitized publication state.",
          "Open Schedules and verify recurrence, authority, destination, next occurrence, and dispatched or missed history agree with PostgreSQL-backed product behavior.",
          "Open Channels and Repositories; verify configuration, membership, continuity, serving worker revisions, and the latest frozen Coop freshness receipt without fetching Git live.",
          "Open Configuration and Model calibration; verify only allowlisted values and grant names render, and that actual admitted lanes show effective target, repairs, tokens, cost, and timing."
        ],
        "/incidents"
      ),
      "</div>"
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

  def episodes(%{items: items, page: page, pages: pages}) do
    rows =
      Enum.map(items, fn item ->
        [
          "<tr><td><a href=\"/episodes/",
          segment(item.ref),
          "\">",
          escape(item.ref),
          "</a></td><td>",
          escape(item.state),
          "</td><td>",
          escape(item.next_action),
          "</td><td>",
          escape(item.destination),
          "</td><td>",
          timestamp(item.updated_at),
          "</td></tr>"
        ]
      end)

    [
      table(["Episode", "State", "Next action", "Destination", "Updated"], rows),
      "<p class=\"pagination\">Page ",
      escape(page),
      " of ",
      escape(pages),
      "</p>"
    ]
  end

  def episode(%{episode: episode, events: events, records: records}) do
    event_rows =
      Enum.map(events, fn event ->
        [
          "<tr><td>",
          timestamp(event.occurred_at),
          "</td><td>",
          escape(event.kind),
          "</td><td>",
          escape(event.summary),
          "</td></tr>"
        ]
      end)

    record_rows =
      Enum.map(records, fn record ->
        [
          "<tr><td>",
          escape(record.kind),
          "</td><td>",
          escape(record.status),
          "</td><td>",
          escape(record.summary),
          "</td></tr>"
        ]
      end)

    [
      definition_list([
        {"Reference", episode.ref},
        {"State", episode.state},
        {"Destination", episode.destination},
        {"Updated", episode.updated_at}
      ]),
      "<section><h2>Timeline</h2>",
      table(["At", "Kind", "Summary"], event_rows),
      "</section><section><h2>Records</h2>",
      table(["Kind", "Status", "Summary"], record_rows),
      "</section>"
    ]
  end

  def incidents(items) do
    rows =
      Enum.map(items, fn item ->
        [
          "<tr><td><a href=\"/incidents/",
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
      workbench_intro(
        "Incident rooms and local incidents",
        "Follow the durable room, linked work, lifecycle, evidence records, and publication without relying on Slack history."
      ),
      search_form("/incidents", "Search title, room, repository, workspace, or channel"),
      table(["Incident", "Status", "Repository", "Channel", "Publication", "Updated"], rows)
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

  def schedules(items) do
    rows =
      Enum.map(items, fn item ->
        [
          "<tr><td><a href=\"/schedules/",
          segment(item.ref),
          "\">",
          escape(item.title),
          "</a><br><code>",
          escape(item.ref),
          "</code></td><td>",
          escape(item.status),
          "</td><td>",
          timestamp(item.next_occurrence_at),
          "</td><td>",
          escape(item.timezone),
          "</td><td>",
          escape(item.repository || "none"),
          "</td><td>",
          integer(item.failures),
          "</td></tr>"
        ]
      end)

    [
      workbench_intro(
        "Recurring and one-shot work",
        "Inspect the exact durable schedule and every dispatched or missed occurrence. Lifecycle controls remain host-confirmed."
      ),
      search_form("/schedules", "Search title, schedule, repository, or destination"),
      table(["Schedule", "Status", "Next", "Timezone", "Repository", "Failures"], rows)
    ]
  end

  def schedule(%{schedule: schedule, occurrences: occurrences}) do
    rows =
      Enum.map(occurrences, fn occurrence ->
        [
          "<tr><td>",
          timestamp(occurrence.scheduled_for),
          "</td><td>",
          escape(occurrence.status),
          "</td><td>",
          episode_link(occurrence.episode_ref),
          "</td><td>",
          escape(occurrence.missed_reason || "—"),
          "</td></tr>"
        ]
      end)

    [
      definition_list([
        {"Reference", schedule.ref},
        {"Status", schedule.status},
        {"Revision", schedule.revision},
        {"Recurrence", schedule.recurrence},
        {"Timezone", schedule.timezone},
        {"Catch-up", schedule.catch_up},
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
      table(["Due", "Outcome", "Episode", "Reason"], rows),
      "</section>"
    ]
  end

  def channels(items) do
    rows =
      Enum.map(items, fn item ->
        [
          "<tr><td><a href=\"/channels/",
          segment(item.workspace_ref),
          "/",
          segment(item.channel_ref),
          "\"><code>",
          escape(item.channel_ref),
          "</code></a><br><span class=\"muted\">",
          escape(item.workspace_ref),
          "</span></td><td>",
          escape(channel_kind(item)),
          "</td><td>",
          escape(item.membership || "not recorded"),
          "</td><td>",
          escape(item.participation || "not configured"),
          "</td><td>",
          escape(item.repository_ref || "none"),
          "</td><td>",
          integer(item.episodes),
          "</td><td>",
          timestamp(item.last_at),
          "</td></tr>"
        ]
      end)

    [
      workbench_intro(
        "Slack conversation roster",
        "A channel remains visible when it has configuration, membership, incident custody, or recorded work."
      ),
      search_form("/channels", "Search workspace, channel, repository, or participation"),
      table(
        [
          "Channel",
          "Kind",
          "Membership",
          "Participation",
          "Repository",
          "Episodes",
          "Last activity"
        ],
        rows
      )
    ]
  end

  def channel(%{
        channel: channel,
        episodes: episodes,
        overrides: overrides,
        schedules: schedules,
        summaries: summaries
      }) do
    override_rows = Enum.map(overrides, &channel_override_row/1)
    schedule_rows = Enum.map(schedules, &channel_schedule_row/1)
    episode_rows = Enum.map(episodes, &channel_episode_row/1)
    summary_rows = Enum.map(summaries, &channel_summary_row/1)

    [
      definition_list([
        {"Workspace", channel.workspace_ref},
        {"Channel", channel.channel_ref},
        {"Kind", if(channel.incident_room, do: "incident room", else: "conversation")},
        {"Channel state", fallback(channel.channel_state, "not recorded")},
        {"Membership", fallback(channel.membership, "not recorded")},
        {"Visibility", channel_visibility(channel.private)},
        {"Participation", fallback(channel.participation, "not configured")},
        {"Repository", fallback(channel.repository_ref, "none")},
        {"Alert policy", fallback(channel.alert_policy, "not configured")},
        {"Configuration revision", fallback(channel.configuration_revision, "none")},
        {"Configuration saved", channel.configuration_saved_at}
      ]),
      "<section><h2>Effective overrides</h2>",
      table(["Setting", "Value", "Scope", "Revision", "Updated"], override_rows),
      "</section><section><h2>Schedules here</h2>",
      table(["Schedule", "Status", "Next"], schedule_rows),
      "</section><section><h2>Conversation continuity</h2>",
      table(["Summary", "Thread", "Repository", "Updated"], summary_rows),
      "</section><section><h2>Recent work</h2>",
      table(["Episode", "State", "Thread", "Updated"], episode_rows),
      "</section>"
    ]
  end

  def repositories(items) do
    rows =
      Enum.map(items, fn item ->
        [
          "<article class=\"repository-card\"><h2><code>",
          escape(item.ref),
          "</code></h2>",
          definition_list([
            {"Configured policies", policy_summary(item.configured)},
            {"Channels", item.channels},
            {"Schedules", item.schedules},
            {"Work sessions", item.sessions},
            {"Publications", item.publications}
          ]),
          "<h3>Latest frozen freshness receipt</h3>",
          freshness_detail(item.freshness),
          "<h3>Serving workers</h3>",
          worker_list(item.workers),
          "</article>"
        ]
      end)

    [
      workbench_intro(
        "Repository topology and freshness",
        "Receipts are the exact Coop-owned evidence frozen before model work. This page does not re-fetch or guess current Git state."
      ),
      search_form("/repositories", "Search repository"),
      if(rows == [],
        do: "<p class=\"empty\">No configured or observed repositories.</p>",
        else: rows
      )
    ]
  end

  def calibration(%{rows: rows, window: window}) do
    body =
      Enum.map(rows, fn row ->
        [
          "<tr><td>",
          escape(row.class),
          "</td><td>",
          escape(row.provider),
          "</td><td>",
          escape(row.model),
          "</td><td>",
          escape(row.effort),
          "</td><td>",
          integer(row.attempts),
          "</td><td>",
          coverage(row.measured, row.attempts),
          "</td><td>",
          integer(row.repair_rounds),
          "</td><td>",
          integer(row.tokens),
          "</td><td>",
          money(row.cost_usd, row.costed),
          "</td><td>",
          duration(row.average_provider_ms),
          "</td><td>",
          duration(row.average_queued_ms),
          "</td><td>",
          duration(row.average_host_ms),
          "</td></tr>"
        ]
      end)

    [
      workbench_intro(
        "Live model-lane calibration",
        "Actual selected class, effective provider/model/effort, semantic repair rounds, timing, tokens, and reported cost. Recorded eval judge scores remain a separate offline corpus result."
      ),
      "<nav class=\"windows\" aria-label=\"Calibration window\">",
      Enum.map(~w(24h 7d 30d all), fn item ->
        [
          "<a href=\"/calibration?window=",
          item,
          "\"",
          if(item == window, do: " aria-current=\"page\"", else: ""),
          ">",
          item,
          "</a>"
        ]
      end),
      "</nav>",
      table(
        [
          "Class",
          "Provider",
          "Model",
          "Effort",
          "Attempts",
          "Measured",
          "Repair rounds",
          "Tokens",
          "Reported USD",
          "Provider avg",
          "Queue avg",
          "Host avg"
        ],
        body
      )
    ]
  end

  def memory(
        %{behaviors: behaviors, memories: memories, schedules: schedules} = snapshot,
        csrf_secret
      ) do
    reviews = Map.get(snapshot, :reviews, [])
    memory_rows = Enum.map(memories, &memory_row/1)
    behavior_rows = Enum.map(behaviors, &behavior_row/1)
    schedule_rows = Enum.map(schedules, &schedule_row/1)
    review_rows = Enum.map(reviews, &review_row/1)

    _secret_is_intentionally_not_rendered = csrf_secret

    [
      "<section><h2>Operational memory</h2>",
      table(["Subject", "Kind", "Status", "Action"], memory_rows),
      "</section><section><h2>Memory review</h2>",
      table(["Kind", "Entries", "Reason", "Action"], review_rows),
      "</section><section><h2>Behaviors</h2>",
      table(["Subject", "Kind", "Status", "Action"], behavior_rows),
      "</section><section><h2>Schedules</h2>",
      table(["Title", "Status", "Next", "Action"], schedule_rows),
      "</section>"
    ]
  end

  defp memory_row(item) do
    [
      "<tr><td>",
      escape(item.subject),
      "</td><td>",
      escape(item.kind),
      "</td><td>",
      escape(item.status),
      "</td><td><a href=\"/actions/memory/",
      segment(item.ref),
      "/forget\">Forget…</a></td></tr>"
    ]
  end

  defp behavior_row(item) do
    next = if item.status == :disabled, do: :active, else: :disabled

    [
      "<tr><td>",
      escape(item.subject),
      "</td><td>",
      escape(item.kind),
      "</td><td>",
      escape(item.status),
      "</td><td><a href=\"/actions/behavior/",
      segment(item.ref),
      "/",
      Atom.to_string(next),
      "\">",
      if(next == :active, do: "Enable…", else: "Disable…"),
      "</a> <a href=\"/actions/behavior/",
      segment(item.ref),
      "/deleted\">Delete…</a></td></tr>"
    ]
  end

  defp schedule_row(item) do
    next = if item.status == :paused, do: :active, else: :paused

    [
      "<tr><td>",
      escape(item.title),
      "</td><td>",
      escape(item.status),
      "</td><td>",
      timestamp(item.next_occurrence_at),
      "</td><td><a href=\"/actions/schedule/",
      segment(item.ref),
      "/",
      Atom.to_string(next),
      "\">",
      if(next == :active, do: "Resume…", else: "Pause…"),
      "</a> <a href=\"/actions/schedule/",
      segment(item.ref),
      "/deleted\">Delete…</a></td></tr>"
    ]
  end

  defp review_row(review) do
    ref = segment(review["review_ref"])

    [
      "<tr><td>",
      escape(review["kind"]),
      "</td><td>",
      Enum.map_join(review["entries"], "<br>", &review_entry/1),
      "</td><td>",
      escape(review["reason"]),
      "</td><td>",
      review_actions(review["kind"], ref),
      "</td></tr>"
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
      "<a href=\"/actions/memory-review/",
      ref,
      "/keep\">",
      if(kind == "duplicate", do: "Keep separate…", else: "Keep…"),
      "</a> ",
      review_secondary_action(kind, ref),
      "<a href=\"/actions/memory-review/",
      ref,
      "/forget\">Forget…</a>"
    ]
  end

  defp review_secondary_action("duplicate", ref),
    do: ["<a href=\"/actions/memory-review/", ref, "/merge\">Merge…</a> "]

  defp review_secondary_action(_kind, ref),
    do: ["<a href=\"/actions/memory-review/", ref, "/edit\">Edit…</a> "]

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
      "<section class=\"confirm\"><h2>",
      escape(title),
      "</h2><p>",
      escape(explanation),
      "</p><form method=\"post\" action=\"",
      escape(action),
      "\"><input type=\"hidden\" name=\"_token\" value=\"",
      escape(token),
      "\"><button class=\"danger\" type=\"submit\">Confirm</button> ",
      "<a class=\"button\" href=\"",
      escape(cancel_path),
      "\">Cancel</a></form></section>"
    ]
  end

  def failures([]),
    do: "<section><h2>Failed custody</h2><p class=\"empty\">No durable failures.</p></section>"

  def failures(rows) do
    body =
      Enum.map(rows, fn row ->
        action =
          case row.action do
            :rearm ->
              [
                "<a href=\"/actions/",
                segment(row.kind),
                "/",
                segment(row.ref),
                "/rearm\">Rearm…</a>"
              ]

            :retry ->
              [
                "<a href=\"/actions/",
                segment(row.kind),
                "/",
                segment(row.ref),
                "/retry\">Retry…</a>"
              ]

            nil ->
              "Inspect the owning episode"
          end

        [
          "<tr><td><a href=\"/failures/",
          segment(row.kind),
          "/",
          segment(row.ref),
          "\">",
          escape(row.kind),
          "</a></td><td>",
          escape(row.ref),
          "</td><td>",
          failure_episode(row),
          "</td><td>",
          escape(Map.get(row, :destination) || Map.get(row, :source) || "not available"),
          "</td><td>",
          integer(Map.get(row, :attempt_count, 0)),
          "</td><td>",
          escape(row.status),
          "</td><td>",
          escape(row.summary),
          "</td><td>",
          timestamp(row.updated_at),
          "</td><td>",
          action,
          "</td></tr>"
        ]
      end)

    [
      "<section><h2>Failed custody</h2>",
      table(
        [
          "Kind",
          "Reference",
          "Episode",
          "Target",
          "Attempts",
          "Status",
          "Cause",
          "Updated",
          "Action"
        ],
        body
      ),
      "</section>"
    ]
  end

  def failure(row) do
    episode =
      case Map.get(row, :episode_ref) do
        nil -> "Before episode admission"
        ref -> ["<a href=\"/episodes/", segment(ref), "\">", escape(ref), "</a>"]
      end

    [
      "<section><h2>Failure context</h2>",
      definition_list([
        {"Kind", row.kind},
        {"Custody reference", row.ref},
        {"Episode", {:safe, episode}},
        {"Source", Map.get(row, :source) || "not available"},
        {"Destination", Map.get(row, :destination) || "not available"},
        {"Attempts", Map.get(row, :attempt_count, 0)},
        {"Status", row.status},
        {"Cause", row.summary},
        {"Detail", Map.get(row, :detail) || "not recorded"},
        {"Updated", timestamp(row.updated_at)}
      ]),
      "<p><a class=\"button\" href=\"/failures\">Back to failures</a></p></section>"
    ]
  end

  def workspaces([]),
    do: "<section><h2>Workspaces</h2><p class=\"empty\">No durable workspaces.</p></section>"

  def workspaces(rows) do
    body =
      Enum.map(rows, fn row ->
        action =
          case row.action do
            :rearm ->
              [
                "<a href=\"/actions/retention/",
                segment(row.ref),
                "/rearm\">Rearm…</a>"
              ]

            :discard_unmerged ->
              [
                "<a href=\"/actions/retention/",
                segment(row.ref),
                "/discard\">Discard unmerged…</a>"
              ]

            nil ->
              "Inspection only"
          end

        [
          "<tr><td>",
          escape(row.ref),
          "</td><td>",
          escape(row.status),
          "</td><td>",
          escape(row.summary),
          "</td><td>",
          escape(row.state),
          "</td><td>",
          timestamp(row.updated_at),
          "</td><td>",
          action,
          "</td></tr>"
        ]
      end)

    [
      "<section><h2>Workspaces</h2>",
      table(["Workspace", "Cleanup", "Reason", "Episode", "Updated", "Action"], body),
      "</section>"
    ]
  end

  def generic(title, rows) when is_list(rows) do
    body =
      case rows do
        [] -> "<p class=\"empty\">No durable records in this view.</p>"
        _ -> Enum.map(rows, &generic_row/1)
      end

    ["<section><h2>", escape(title), "</h2>", body, "</section>"]
  end

  def configuration(%{rows: rows, grants: grants, source: source}) do
    configuration_rows =
      Enum.map(rows, fn row ->
        [
          "<tr><td><code>",
          escape(row.key),
          "</code></td><td>",
          escape(row.value),
          "</td><td><code>",
          escape(row.source),
          "</code></td></tr>"
        ]
      end)

    grant_rows =
      Enum.map(grants, fn grant ->
        [
          "<tr><td>",
          escape(grant.kind),
          "</td><td><code>",
          escape(grant.name),
          "</code></td><td><code>",
          escape(grant.source),
          "</code></td></tr>"
        ]
      end)

    [
      workbench_intro(
        "Effective host configuration",
        "Only an explicit safe allowlist is rendered. Credentials, URLs, callback values, and raw policy documents remain private."
      ),
      "<p class=\"muted\">Loaded from <code>",
      escape(source),
      "</code>.</p><section><h2>Effective values and provenance</h2>",
      table(["Setting", "Effective value", "Source"], configuration_rows),
      "</section><section><h2>MCP and tool grants</h2>",
      table(["Grant kind", "Capability or tool", "Source"], grant_rows),
      "</section><p class=\"muted\">Repository-specific policy topology and serving-worker revisions are shown under <a href=\"/repositories\">Repositories</a>.</p>"
    ]
  end

  def configuration(rows), do: generic("Effective host configuration", rows)

  def usage(%{totals: totals} = snapshot) do
    target_rows =
      Enum.map(snapshot.targets, fn row ->
        target = row.target || "unrecorded"

        target_cell =
          if row.target do
            [
              "<a href=\"/episodes?",
              escape(URI.encode_query(%{"target" => row.target})),
              "\">",
              escape(target),
              "</a>"
            ]
          else
            escape(target)
          end

        [
          "<tr><td>",
          target_cell,
          "</td><td>",
          escape(row.provider),
          "</td><td>",
          escape(row.model),
          "</td><td>",
          escape(row.effort),
          "</td><td>",
          integer(row.attempts),
          "</td><td>",
          coverage(row.measured, row.attempts),
          "</td><td>",
          integer(row.tokens),
          "</td><td>",
          money(row.cost_usd, row.costed),
          "</td></tr>"
        ]
      end)

    channel_rows =
      Enum.map(snapshot.channels, fn row ->
        label = "#{row.transport}:#{row.conversation_ref}"

        [
          "<tr><td><a href=\"/episodes?",
          escape(URI.encode_query(%{"q" => row.conversation_ref})),
          "\">",
          escape(label),
          "</a></td><td>",
          integer(row.attempts),
          "</td><td>",
          coverage(row.measured, row.attempts),
          "</td><td>",
          integer(row.tokens),
          "</td><td>",
          money(row.cost_usd, row.costed),
          "</td></tr>"
        ]
      end)

    repository_rows =
      Enum.map(snapshot.repositories, fn row ->
        label = row.repository_ref || "no repository"

        repository_cell =
          if row.repository_ref do
            [
              "<a href=\"/episodes?",
              escape(URI.encode_query(%{"repository" => row.repository_ref})),
              "\">",
              escape(label),
              "</a>"
            ]
          else
            escape(label)
          end

        [
          "<tr><td>",
          repository_cell,
          "</td><td>",
          integer(row.attempts),
          "</td><td>",
          coverage(row.measured, row.attempts),
          "</td><td>",
          integer(row.tokens),
          "</td><td>",
          money(row.cost_usd, row.costed),
          "</td></tr>"
        ]
      end)

    [
      "<nav class=\"windows\" aria-label=\"Usage window\">",
      Enum.map(~w(24h 7d 30d all), fn window ->
        [
          "<a href=\"/usage?window=",
          window,
          "\"",
          if(window == snapshot.window, do: " aria-current=\"page\"", else: ""),
          ">",
          window,
          "</a>"
        ]
      end),
      "</nav><section class=\"metrics\">",
      metric("Attempts", totals.attempts),
      metric("Provider measured", coverage(totals.usage_measured, totals.attempts)),
      metric("Reported USD", money(totals.cost_usd, totals.costed)),
      metric("Total tokens", total_tokens(totals)),
      "</section><section><h2>Coverage and timing</h2>",
      definition_list([
        {"Cache hit rate", percent(totals.cache_hit_rate)},
        {"Timed turns", coverage(totals.timed, totals.attempts)},
        {"Average queued", duration(totals.average_queued_ms)},
        {"Average provider", duration(totals.average_provider_ms)},
        {"Average host observation", duration(totals.average_host_ms)},
        {"Measurement errors", totals.measurement_errors}
      ]),
      "<p class=\"muted\">Reported money is shown only when the provider supplied it; unpriced attempts are not displayed as zero spend.</p>",
      "</section><section><h2>Daily token trend</h2>",
      trend_svg(snapshot.days),
      "</section><section><h2>Execution targets</h2>",
      table(
        [
          "Target",
          "Provider",
          "Model",
          "Effort",
          "Attempts",
          "Measured",
          "Tokens",
          "Reported USD"
        ],
        target_rows
      ),
      "</section><section><h2>Destinations</h2>",
      table(["Destination", "Attempts", "Measured", "Tokens", "Reported USD"], channel_rows),
      "</section><section><h2>Repositories</h2>",
      table(["Repository", "Attempts", "Measured", "Tokens", "Reported USD"], repository_rows),
      "</section>"
    ]
  end

  def css do
    """
    :root{color-scheme:dark;--bg:#080a0d;--panel:#13171c;--panel-raised:#191f26;--text:#f3f4ef;--muted:#95a0ac;--line:#29323c;--accent:#c6ff47;--cyan:#79e8ff;--danger:#ff776d;--warning:#ffc857}
    *{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 85% -10%,#142530 0,transparent 34rem),var(--bg);color:var(--text);font-family:ui-sans-serif,system-ui,-apple-system,sans-serif;line-height:1.5}
    header{position:sticky;top:0;background:#080a0df2;border-bottom:1px solid var(--line);padding:1rem 2rem;z-index:2;backdrop-filter:blur(12px)}.brand{color:var(--accent);font-weight:900;letter-spacing:.02em;text-decoration:none}nav{display:flex;flex-wrap:wrap;gap:.8rem;margin-top:.7rem}nav a,a{color:#c9e7ff}main{max-width:1180px;margin:0 auto;padding:2rem}footer{max-width:1180px;margin:2rem auto;padding:1rem 2rem;color:var(--muted);border-top:1px solid var(--line)}
    h1{font-size:clamp(1.8rem,4vw,2.7rem);letter-spacing:-.035em}h2{margin-top:2rem;letter-spacing:-.02em}.metrics{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:1rem}.metric,section.confirm{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:1rem}.metric strong{display:block;font-size:2rem}.metric span,.muted,.empty{color:var(--muted)}
    table{border-collapse:collapse;width:100%;background:var(--panel)}th,td{border-bottom:1px solid var(--line);padding:.75rem;text-align:left;vertical-align:top}th{color:var(--muted);font-size:.8rem;text-transform:uppercase}dl{display:grid;grid-template-columns:max-content 1fr;gap:.5rem 1rem}dt{color:var(--muted)}dd{margin:0;overflow-wrap:anywhere}
    button,.button{background:var(--accent);border:0;border-radius:7px;color:#0a0b0d;display:inline-block;font:inherit;font-weight:700;padding:.65rem .9rem;text-decoration:none}.danger{background:var(--danger)}.windows{margin:0 0 1rem}.windows a[aria-current=page]{color:var(--accent);font-weight:800}.trend{background:var(--panel);border:1px solid var(--line);border-radius:12px;display:block;max-width:100%;width:100%}.trend rect{fill:var(--accent)}
    code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.9em}.eyebrow{color:var(--accent);font-size:.72rem;font-weight:900;letter-spacing:.16em;margin:0 0 .4rem;text-transform:uppercase}.lab-hero,.journey-intro{align-items:center;background:linear-gradient(125deg,#18222b,#101419 70%);border:1px solid #34414d;border-radius:18px;display:flex;gap:2rem;justify-content:space-between;padding:clamp(1.3rem,4vw,2.5rem)}.lab-hero h2,.journey-intro h2{font-size:clamp(1.5rem,3vw,2.35rem);margin:.15rem 0}.lab-hero p,.journey-intro p{color:#b8c2cc;max-width:68ch}.lab-shell{background:#0d1116;border:1px solid var(--line);border-radius:18px;overflow:hidden}.lab-heading{align-items:flex-start;background:linear-gradient(120deg,#182029,#10151b);border-bottom:1px solid var(--line);display:flex;justify-content:space-between;padding:1.4rem}.lab-heading h2{margin:.1rem 0}.lab-heading p{margin:.2rem 0}.lab-safety-note{background:#142017;border-bottom:1px solid #334d36;color:#c7d6c5;margin:0;padding:.75rem 1.4rem}.lab-safety-note strong{color:var(--accent)}.status-cluster{align-items:flex-end;display:flex;flex-direction:column;gap:.55rem}.status{border:1px solid var(--line);border-radius:999px;font-size:.72rem;font-weight:900;letter-spacing:.08em;padding:.3rem .65rem;text-transform:uppercase}.status.live{border-color:#587425;color:var(--accent)}.status.waiting{border-color:#6f5b2d;color:var(--warning)}.status.blocked{border-color:#7f3a39;color:var(--danger)}.quiet-link{color:var(--muted);font-size:.82rem}.lab-stream{display:grid;grid-template-columns:minmax(0,1fr) 260px;min-height:280px}.messages{display:flex;flex-direction:column;gap:1rem;padding:1.4rem}.message{border:1px solid var(--line);border-radius:14px;max-width:86%;padding:.9rem 1rem}.message.operator{align-self:flex-end;background:#243420;border-color:#3f5d35}.message.integration{align-self:flex-start;background:#171b20;border-color:#5c6570;border-style:dashed;color:#d5dbe1}.message.responder{align-self:flex-start;background:var(--panel-raised);border-color:#344553}.message-head{align-items:center;color:var(--muted);display:flex;font-size:.72rem;gap:.65rem;justify-content:space-between;margin-bottom:.45rem;text-transform:uppercase}.message-body{overflow-wrap:anywhere;white-space:pre-wrap}.message-refs{display:flex;flex-wrap:wrap;gap:.35rem;margin:.65rem 0 0}.message-refs code{background:#0c1014;border-radius:5px;color:var(--cyan);padding:.15rem .35rem}.custody-strip{background:#0a0e12;border-left:1px solid var(--line);padding:1.25rem}.custody-strip strong{color:var(--cyan);font-size:.76rem;letter-spacing:.1em;text-transform:uppercase}.custody-strip ul{list-style:none;margin:1rem 0;padding:0}.custody-strip li{border-top:1px solid var(--line);padding:.7rem 0}.custody-strip li span{color:var(--muted);display:block;font-size:.78rem}.composer{border-top:1px solid var(--line);padding:1.25rem}.composer label{display:block;font-size:.8rem;font-weight:800;margin-bottom:.45rem;text-transform:uppercase}.composer textarea,.composer input[type=file]{background:#090d11;border:1px solid #3a4652;border-radius:10px;color:var(--text);font:inherit;padding:.85rem;width:100%}.composer textarea{resize:vertical}.composer textarea:focus,.composer input[type=file]:focus{border-color:var(--accent);outline:2px solid #c6ff4730}.composer .attachment-label{margin-top:.8rem}.composer-actions{align-items:center;color:var(--muted);display:flex;font-size:.78rem;gap:1rem;justify-content:space-between;margin-top:.8rem}.journey-grid{display:grid;gap:1rem;grid-template-columns:repeat(2,minmax(0,1fr));margin-top:1rem}.journey{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:1.2rem}.journey h2{font-size:1.2rem;margin:.2rem 0 .8rem}.journey-number{color:var(--cyan);font-family:ui-monospace,SFMono-Regular,Menlo,monospace}.journey ol{color:#c6ccd2;padding-left:1.2rem}.journey .availability{color:var(--muted);font-size:.75rem;font-weight:800;text-transform:uppercase}.journey .availability.enabled{color:var(--accent)}
    .message-reactions{display:flex;gap:.35rem;margin-top:.55rem}.reaction-chip{background:#1c2831;border:1px solid #3b5364;border-radius:999px;color:#d8f6ff;font-family:var(--mono);font-size:.75rem;padding:.2rem .5rem}.message-attachments{display:grid;gap:.55rem;margin-top:.7rem}.attachment-chip{background:#101920;border:1px solid #3b5364;border-radius:8px;color:#d8f6ff;display:flex;flex-wrap:wrap;font-size:.78rem;gap:.45rem;padding:.45rem .6rem}.attachment-chip span{color:var(--muted)}.attachment-download{color:inherit;display:grid;gap:.45rem;text-decoration:none}.attachment-download img{background:#080a0d;border:1px solid var(--line);border-radius:8px;display:block;max-height:280px;max-width:100%;object-fit:contain}.lab-message-controls{align-items:flex-start;border-top:1px solid #3f5d35;display:flex;gap:.55rem;justify-content:flex-end;margin-top:.8rem;padding-top:.65rem}.lab-message-controls details{flex:1}.lab-message-controls summary{cursor:pointer;font-size:.75rem;font-weight:800}.lab-message-controls label{display:grid;font-size:.72rem;gap:.35rem;margin-top:.55rem}.lab-message-controls textarea{background:#090d11;border:1px solid #3a4652;border-radius:8px;color:var(--text);font:inherit;padding:.6rem;resize:vertical;width:100%}.danger-button{border:1px solid #7f3a39;color:#ffb3ad}.message-cards{display:grid;gap:.7rem;margin-top:.85rem}.lab-card{background:#0e1419;border:1px solid #344553;border-left:3px solid var(--cyan);border-radius:10px;padding:.85rem}.lab-card-head{color:var(--cyan);display:flex;font-size:.68rem;font-weight:900;gap:1rem;justify-content:space-between;letter-spacing:.1em;text-transform:uppercase}.lab-card h3{font-size:1rem;margin:.45rem 0}.lab-card p{color:#cbd3da;margin:.35rem 0;white-space:pre-wrap}.lab-card dl{font-size:.78rem;grid-template-columns:max-content minmax(0,1fr);margin:.65rem 0}.choice-list{display:flex;flex-wrap:wrap;gap:.4rem;margin-top:.65rem}.choice-chip{background:#1c2831;border:1px solid #3b5364;border-radius:999px;color:#d8f6ff;font-size:.78rem;padding:.25rem .55rem}
    .lab-reaction-controls{border-top:1px solid #344553;margin-top:.8rem;padding-top:.65rem}.reaction-label{color:var(--muted);display:block;font-size:.7rem;font-weight:800;letter-spacing:.07em;margin-bottom:.45rem;text-transform:uppercase}.quick-reactions,.feedback-reactions{align-items:center;display:flex;flex-wrap:wrap;gap:.35rem}.feedback-reactions{margin-bottom:.45rem}.reaction-form{display:inline}.reaction-form button{background:#1c2831;border:1px solid #3b5364;color:#d8f6ff;font-size:.75rem;padding:.3rem .5rem}.feedback-reaction{align-items:center;background:#142017;border:1px solid #3f5d35;border-radius:999px;display:inline-flex;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.75rem;gap:.25rem;padding-left:.5rem}.feedback-reaction button{border:0;border-left:1px solid #3f5d35;border-radius:0 999px 999px 0;padding:.2rem .4rem}.lab-reaction-controls details{margin-top:.45rem}.lab-reaction-controls summary{cursor:pointer;font-size:.72rem}.lab-reaction-controls label{display:flex;font-size:.72rem;gap:.4rem;margin-top:.4rem}.lab-reaction-controls input[name=emoji]{background:#090d11;border:1px solid #3a4652;border-radius:7px;color:var(--text);font:inherit;padding:.35rem}.danger-button{background:#261312}.lab-card-actions{display:flex;flex-wrap:wrap;gap:.5rem;margin-top:.75rem}.lab-card-actions form{margin:0}.lab-card-actions button,.lab-card-actions .button{font-size:.82rem;padding:.5rem .7rem}.work-view{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:1.2rem}.work-view pre{background:#090d11;border:1px solid var(--line);border-radius:10px;color:#dbe7ef;overflow:auto;padding:1rem;white-space:pre-wrap}.work-view-actions{align-items:center;display:flex;flex-wrap:wrap;gap:.7rem;margin-top:1rem}
    .workbench-intro{background:linear-gradient(125deg,#18222b,#101419 70%);border:1px solid #34414d;border-radius:16px;padding:1.4rem}.workbench-intro h2{margin:.15rem 0}.workbench-intro p:last-child{color:#b8c2cc;max-width:78ch}.search-form{align-items:end;display:grid;gap:.7rem;grid-template-columns:auto minmax(220px,1fr) auto;margin:1.2rem 0}.search-form label{color:var(--muted);font-size:.78rem;font-weight:800;text-transform:uppercase}.search-form input{background:#090d11;border:1px solid #3a4652;border-radius:8px;color:var(--text);font:inherit;padding:.65rem}.repository-card{background:var(--panel);border:1px solid var(--line);border-radius:14px;margin:1rem 0;padding:1.2rem}.repository-card h2{margin:0}.repository-card h3{color:var(--cyan);font-size:.82rem;letter-spacing:.07em;margin-top:1.5rem;text-transform:uppercase}.record-body{background:#090d11;border:1px solid var(--line);border-radius:10px;color:#dbe7ef;overflow:auto;padding:1rem;white-space:pre-wrap}
    @media(max-width:760px){header,main{padding-left:1rem;padding-right:1rem}.lab-hero,.lab-heading{align-items:stretch;flex-direction:column}.lab-stream{grid-template-columns:1fr}.custody-strip{border-left:0;border-top:1px solid var(--line)}.message{max-width:96%}.composer-actions{align-items:stretch;flex-direction:column}.journey-grid{grid-template-columns:1fr}.search-form{grid-template-columns:1fr}}
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
      "</span><span>",
      escape(card.status),
      "</span></div><h3>",
      escape(card.title),
      "</h3>",
      if(card.summary, do: ["<p>", escape(card.summary), "</p>"], else: ""),
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
        if(is_binary(Map.get(control, :review_offer_ref)),
          do: [
            "<input type=\"hidden\" name=\"review_offer_ref\" value=\"",
            escape(control.review_offer_ref),
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

  defp journey(number, title, enabled, steps, link \\ nil, example \\ nil) do
    [
      "<article class=\"journey\"><div class=\"journey-number\">",
      escape(number),
      "</div><span class=\"availability ",
      if(enabled, do: "enabled", else: "disabled"),
      "\">",
      if(enabled, do: "Configured", else: "Not configured"),
      "</span><h2>",
      escape(title),
      "</h2><ol>",
      Enum.map(steps, &["<li>", escape(&1), "</li>"]),
      "</ol>",
      if(link,
        do: ["<a class=\"button\" href=\"", escape(link), "\">Open journey</a>"],
        else: ""
      ),
      example || "",
      "</article>"
    ]
  end

  defp failure_episode(row) do
    case Map.get(row, :episode_ref) do
      nil -> "Before admission"
      ref -> ["<a href=\"/episodes/", segment(ref), "\">", escape(ref), "</a>"]
    end
  end

  defp webhook_example do
    example = """
    export RESPONDER_WEBHOOK_SECRET='replace-with-the-configured-route-secret'
    url='http://127.0.0.1:4320/v1/hooks/universal'
    path='/v1/hooks/universal'
    body='{"kind":"manual-test","request":"Report the exact observed fields without inferring vendor meaning.","payload":{"message":"hello from the universal adapter"}}'
    timestamp=$(date +%s)
    event_id="manual-$(uuidgen | tr '[:upper:]' '[:lower:]')"
    item_id='manual-conversation-1'
    event_type='manual.test'
    occurred_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    revision='1'
    signed=$(printf '%s\\n' "$timestamp" "$path" "$event_id" "$item_id" "$event_type" "$occurred_at" "$revision"; printf '%s' "$body")
    signature=$(RESPONDER_SIGNED="$signed" elixir -e 'System.fetch_env!("RESPONDER_SIGNED") |> then(&:crypto.mac(:hmac, :sha256, System.fetch_env!("RESPONDER_WEBHOOK_SECRET"), &1)) |> Base.encode16(case: :lower) |> IO.write()')

    curl --fail-with-body -X POST "$url" \\
      -H 'Content-Type: application/json' \\
      -H "X-Responder-Timestamp: $timestamp" \\
      -H "X-Responder-Signature: v1=$signature" \\
      -H "X-Responder-Event-ID: $event_id" \\
      -H "X-Responder-Item-ID: $item_id" \\
      -H "X-Responder-Event-Type: $event_type" \\
      -H "X-Responder-Occurred-At: $occurred_at" \\
      -H "X-Responder-Revision: $revision" \\
      --data-binary "$body"
    """

    [
      "<details><summary>Copy the HMAC signing request</summary><pre><code>",
      escape(example),
      "</code></pre></details>"
    ]
  end

  defp metric(label, value) do
    [
      "<article class=\"metric\"><strong>",
      escape(value),
      "</strong><span>",
      escape(label),
      "</span></article>"
    ]
  end

  defp workbench_intro(title, description) do
    [
      "<section class=\"workbench-intro\"><p class=\"eyebrow\">Durable operator view</p><h2>",
      escape(title),
      "</h2><p>",
      escape(description),
      "</p></section>"
    ]
  end

  defp search_form(path, placeholder) do
    [
      "<form class=\"search-form\" method=\"get\" action=\"",
      escape(path),
      "\"><label for=\"operator-search\">Search</label><input id=\"operator-search\" name=\"q\" maxlength=\"200\" placeholder=\"",
      escape(placeholder),
      "\"><button type=\"submit\">Search</button></form>"
    ]
  end

  defp channel_label(workspace_ref, nil), do: "#{workspace_ref}:not provisioned"
  defp channel_label(workspace_ref, channel_ref), do: "#{workspace_ref}:#{channel_ref}"

  defp channel_kind(%{incident_room: true}), do: "incident room"
  defp channel_kind(%{channel_ref: "D" <> _rest}), do: "direct message"
  defp channel_kind(_item), do: "shared channel"

  defp channel_visibility(true), do: "private"
  defp channel_visibility(_public_or_unknown), do: "public or unrecorded"

  defp channel_override_row(item) do
    [
      "<tr><td>",
      escape(item.setting),
      "</td><td>",
      escape(item.value),
      "</td><td>",
      escape(item.scope),
      "</td><td>",
      integer(item.revision),
      "</td><td>",
      timestamp(item.updated_at),
      "</td></tr>"
    ]
  end

  defp channel_schedule_row(item) do
    [
      "<tr><td><a href=\"/schedules/",
      segment(item.ref),
      "\">",
      escape(item.title),
      "</a></td><td>",
      escape(item.status),
      "</td><td>",
      timestamp(item.next_occurrence_at),
      "</td></tr>"
    ]
  end

  defp channel_episode_row(item) do
    [
      "<tr><td>",
      episode_link(item.ref),
      "</td><td>",
      escape(item.state),
      "</td><td>",
      escape(fallback(item.thread_ref, "channel root")),
      "</td><td>",
      timestamp(item.updated_at),
      "</td></tr>"
    ]
  end

  defp channel_summary_row(item) do
    [
      "<tr><td><code>",
      escape(item.ref),
      "</code></td><td>",
      escape(fallback(item.thread_ref, "channel root")),
      "</td><td>",
      escape(fallback(item.repository_ref, "none")),
      "</td><td>",
      timestamp(item.updated_at),
      "</td></tr>"
    ]
  end

  defp fallback(nil, replacement), do: replacement
  defp fallback(value, _replacement), do: value

  defp episode_link(nil), do: "—"

  defp episode_link(ref) do
    IO.iodata_to_binary([
      "<a href=\"/episodes/",
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

  defp worker_list([]), do: "<p class=\"empty\">No live worker advertises this repository.</p>"

  defp worker_list(workers) do
    rows =
      Enum.map(workers, fn worker ->
        [
          "<tr><td><code>",
          escape(worker.worker_ref),
          "</code></td><td>",
          escape(worker.state),
          "</td><td><code>",
          escape(worker.revision || "unrecorded"),
          "</code></td><td>",
          timestamp(worker.last_seen_at),
          "</td></tr>"
        ]
      end)

    table(["Worker", "State", "Advertised revision", "Last seen"], rows)
  end

  defp trend_svg([]), do: "<p class=\"empty\">No accepted turns in this window.</p>"

  defp trend_svg(days) do
    maximum = days |> Enum.map(& &1.tokens) |> Enum.max(fn -> 0 end) |> max(1)
    width = max(length(days) * 28, 280)

    bars =
      days
      |> Enum.with_index()
      |> Enum.map(fn {day, index} ->
        height = max(round(day.tokens / maximum * 96), if(day.tokens > 0, do: 1, else: 0))
        x = index * 28 + 4
        y = 104 - height

        [
          "<rect x=\"",
          integer(x),
          "\" y=\"",
          integer(y),
          "\" width=\"20\" height=\"",
          integer(height),
          "\"><title>",
          escape("#{day.date}: #{day.tokens} tokens, #{day.measured}/#{day.attempts} measured"),
          "</title></rect>"
        ]
      end)

    [
      "<svg class=\"trend\" role=\"img\" aria-label=\"Daily measured token trend\" viewBox=\"0 0 ",
      integer(width),
      " 108\" preserveAspectRatio=\"none\">",
      bars,
      "</svg>"
    ]
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

  defp segment(value), do: value |> to_string() |> URI.encode(&URI.char_unreserved?/1)

  defp total_tokens(totals) do
    integer(
      totals.input_tokens + totals.cached_input_tokens + totals.output_tokens +
        totals.reasoning_tokens
    )
  end

  defp coverage(_measured, 0), do: "0 of 0"
  defp coverage(measured, attempts), do: "#{measured} of #{attempts}"

  defp percent(nil), do: "unmeasured"
  defp percent(value), do: :erlang.float_to_binary(value * 100, decimals: 1) <> "%"

  defp duration(nil), do: "unmeasured"

  defp duration(milliseconds),
    do: :erlang.float_to_binary(milliseconds / 1_000, decimals: 2) <> " s"

  defp money(_amount, 0), do: "unreported"
  defp money(%Decimal{} = amount, _count), do: "$" <> Decimal.to_string(amount, :normal)
  defp money(amount, _count), do: "$" <> to_string(amount)

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
