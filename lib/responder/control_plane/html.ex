defmodule Responder.ControlPlane.HTML do
  alias Responder.Accounting.Pricing
  alias Responder.ControlPlane.Components
  alias Responder.ControlPlane.FailurePage
  alias Responder.ControlPlane.SlackNames
  alias Responder.ControlPlane.UsagePage
  alias Responder.ControlPlane.UsageProjection
  @moduledoc false

  @native_slack_path Path.expand("../../../priv/static/native-slack.css", __DIR__)
  @external_resource @native_slack_path
  @native_slack_css File.read!(@native_slack_path)

  @spec page(String.t(), iodata()) :: binary()
  alias Phoenix.HTML.Safe
  alias Responder.ControlPlane.CaseFile
  alias Responder.ControlPlane.ConfigurationHelp
  alias Responder.ControlPlane.Layouts
  alias Responder.ControlPlane.SlackMarkdown

  def page(title, body) do
    %{title: title, body: IO.iodata_to_binary(body)}
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

  def card_lab(snapshot, feedback, transition_tokens, feedback_token, slack_panel \\ []) do
    selected_path = card_lab_path(snapshot.card.id, snapshot.state.id)
    specimen_count = Enum.sum(Enum.map(snapshot.catalog, & &1.state_count))

    catalog =
      Enum.map(snapshot.catalog, fn card ->
        [
          "<li",
          if(card.id == snapshot.card.id, do: " class=\"selected\"", else: ""),
          "><a href=\"/card-lab/",
          segment(card.id),
          "/",
          segment(card.first_state_id),
          "\"><span>",
          escape(card.title),
          "</span><small>",
          integer(card.state_count),
          " states · ",
          escape(card.surface),
          "</small></a></li>"
        ]
      end)

    state_tabs =
      Enum.map(snapshot.card.states, fn state ->
        [
          "<a href=\"/card-lab/",
          segment(snapshot.card.id),
          "/",
          segment(state.id),
          "\"",
          if(state.id == snapshot.state.id, do: " aria-current=\"page\"", else: ""),
          ">",
          escape(state.label),
          "</a>"
        ]
      end)

    transitions =
      case snapshot.state.transitions do
        [] -> "<p class=\"card-lab-empty\">This specimen has no outgoing state transition.</p>"
        rows -> Enum.map(rows, &card_lab_transition(snapshot, &1, transition_tokens))
      end

    feedback_rows =
      case feedback do
        [] -> "<p class=\"card-lab-empty\">No feedback on this exact state yet.</p>"
        rows -> Enum.map(rows, &card_lab_feedback_row/1)
      end

    [
      "<section class=\"card-lab-hero\"><div><p class=\"eyebrow\">Local specimen workbench</p>",
      "<h2>Every production Slack surface, ready to review</h2>",
      "<p>Inspect production-renderer output, walk declared state transitions, and leave feedback on the precise state. Use Post to Slack for native rendering in a confirmed test destination.</p></div>",
      "<div class=\"card-lab-totals\"><strong>",
      integer(specimen_count),
      "</strong><span>specimens</span><strong>",
      integer(length(snapshot.catalog)),
      "</strong><span>families</span></div></section>",
      "<section class=\"card-lab-shell\"><aside class=\"card-lab-catalog\"><div class=\"card-lab-panel-head\"><span>Catalog</span><small>Production surfaces</small></div><ul>",
      catalog,
      "</ul></aside><div class=\"card-lab-stage\"><div class=\"card-lab-stage-head\"><div><p class=\"eyebrow\">",
      escape(snapshot.card.surface),
      " · Production renderer</p><h2>",
      escape(snapshot.card.title),
      "</h2><p>",
      escape(snapshot.card.description),
      "</p></div><span class=\"card-lab-state-count\">",
      integer(length(snapshot.card.states)),
      " states</span></div><nav class=\"card-lab-state-tabs\" aria-label=\"Card states\">",
      state_tabs,
      "</nav><div class=\"card-lab-current\"><div><span>Current specimen</span><h3>",
      escape(snapshot.state.label),
      "</h3><p>",
      escape(snapshot.state.description),
      "</p></div><code>",
      escape(snapshot.card.id),
      "/",
      escape(snapshot.state.id),
      "</code></div>",
      card_lab_preview(snapshot.rendered, snapshot.card.surface),
      "<p class=\"muted\">Browser approximation · Slack is the rendering authority. Use Post to Slack to verify layout and wrapping.</p>",
      "<details class=\"card-lab-json\"><summary>Raw Block Kit JSON</summary><pre><code>",
      escape(Jason.encode!(snapshot.rendered, pretty: true)),
      "</code></pre></details></div><aside class=\"card-lab-inspector\">",
      slack_panel,
      "<section><p class=\"eyebrow\">State reducer</p><h2>Transition without Slack</h2><p>These controls select the next deterministic fixture. They do not run the production action behind a previewed Slack button.</p><div class=\"card-lab-transitions\">",
      transitions,
      "</div></section><section id=\"feedback\"><p class=\"eyebrow\">Review notes</p><h2>Feedback on this state</h2><form class=\"card-lab-feedback-form\" method=\"post\" action=\"",
      selected_path,
      "/feedback\"><input type=\"hidden\" name=\"_token\" value=\"",
      escape(feedback_token),
      "\"><fieldset><legend>Verdict</legend>",
      card_lab_verdict("needs_work", "Needs work", true),
      card_lab_verdict("good", "Good", false),
      card_lab_verdict("approved", "Approved", false),
      "</fieldset><label>What should change?<textarea name=\"note\" maxlength=\"4000\" rows=\"5\" required placeholder=\"Be specific about hierarchy, copy, controls, missing context, or state behavior.\"></textarea></label><button type=\"submit\">Save feedback</button></form><div class=\"card-lab-feedback-list\">",
      feedback_rows,
      "</div></section></aside></section>"
    ]
  end

  defp card_lab_transition(snapshot, transition, tokens) do
    [
      "<form method=\"post\" action=\"/card-lab/",
      segment(snapshot.card.id),
      "/",
      segment(snapshot.state.id),
      "/transitions/",
      segment(transition.id),
      "\"><input type=\"hidden\" name=\"_token\" value=\"",
      escape(Map.fetch!(tokens, transition.id)),
      "\"><button type=\"submit\"><span>",
      escape(transition.label),
      "</span><small>→ ",
      escape(transition.to),
      "</small></button></form>"
    ]
  end

  defp card_lab_verdict(value, label, checked) do
    [
      "<label><input type=\"radio\" name=\"verdict\" value=\"",
      value,
      "\"",
      if(checked, do: " checked", else: ""),
      ">",
      escape(label),
      "</label>"
    ]
  end

  defp card_lab_feedback_row(row) do
    [
      "<article data-verdict=\"",
      escape(row.verdict),
      "\"><header><strong>",
      escape(String.replace(row.verdict, "_", " ")),
      "</strong><time>",
      timestamp(row.inserted_at),
      "</time></header><p>",
      escape(row.note),
      "</p><small>",
      escape(row.actor_ref),
      "</small></article>"
    ]
  end

  @doc false
  def card_lab_preview(%{"type" => "thread_status", "status" => status}, _surface) do
    [
      "<div class=\"slack-canvas thread-status-canvas\"><div class=\"slack-thread-head\"><span class=\"slack-avatar\">R</span><div><strong>Responder</strong><small>APP · thread</small></div></div><div class=\"slack-thread-status",
      if(status == "", do: " clear", else: ""),
      "\"><span class=\"status-pulse\"></span>",
      if(status == "", do: "Status cleared", else: escape(status)),
      "</div></div>"
    ]
  end

  def card_lab_preview(rendered, surface) when surface in [:app_home, :modal] do
    [
      "<div class=\"slack-canvas surface-",
      escape(surface),
      "\"><div class=\"slack-chrome\"><strong>",
      if(surface == :modal,
        do: escape(get_in(rendered, ["title", "text"]) || "Modal"),
        else: "Responder · Home"
      ),
      "</strong><small>",
      if(surface == :modal, do: "Modal preview", else: "App Home preview"),
      "</small></div><div class=\"slack-native-view\">",
      Enum.map(Map.get(rendered, "blocks", []), &slack_block/1),
      "</div>",
      if(surface == :modal,
        do: [
          "<div class=\"slack-modal-footer\">",
          escape(get_in(rendered, ["close", "text"]) || "Close"),
          " · ",
          escape(get_in(rendered, ["submit", "text"]) || "Submit"),
          "</div>"
        ],
        else: []
      ),
      "</div>"
    ]
  end

  def card_lab_preview(rendered, surface) do
    [
      "<div class=\"slack-canvas surface-",
      escape(surface),
      "\"><div class=\"slack-chrome\"><strong># responder-card-lab</strong><small>Message preview</small></div><article class=\"slack-message-preview\"><span class=\"slack-avatar\">R</span><div class=\"slack-message-content\"><header><strong>Responder</strong><span>APP</span><time>12:04</time></header>",
      Enum.map(Map.get(rendered, "blocks", []), &slack_block/1),
      "</div></article>",
      if(rendered["text"],
        do: [
          "<div class=\"slack-fallback\"><strong>Fallback text</strong><span>",
          escape(rendered["text"]),
          "</span></div>"
        ],
        else: ""
      ),
      "</div>"
    ]
  end

  defp slack_block(%{"type" => "markdown", "text" => text}),
    do: [
      "<div class=\"slack-block slack-markdown\">",
      SlackMarkdown.render(text),
      "</div>"
    ]

  defp slack_block(%{"type" => "section"} = block) do
    [
      "<div class=\"slack-block slack-section\"><div>",
      slack_text(block["text"]),
      slack_fields(block["fields"]),
      "</div>",
      if(block["accessory"],
        do: ["<aside>", slack_element(block["accessory"]), "</aside>"],
        else: ""
      ),
      "</div>"
    ]
  end

  defp slack_block(%{"type" => "actions", "elements" => elements}) do
    ["<div class=\"slack-block slack-actions\">", Enum.map(elements, &slack_element/1), "</div>"]
  end

  defp slack_block(%{"type" => "header", "text" => text}),
    do: ["<div class=\"slack-block slack-header\">", slack_text(text), "</div>"]

  defp slack_block(%{"type" => "context", "elements" => elements}),
    do: ["<div class=\"slack-block slack-context\">", Enum.map(elements, &slack_text/1), "</div>"]

  defp slack_block(%{"type" => "divider"}), do: "<hr class=\"slack-divider\">"

  defp slack_block(%{"type" => "input", "label" => label, "element" => element}),
    do: [
      "<label class=\"slack-block slack-input\"><span>",
      slack_text(label),
      "</span>",
      slack_element(element),
      "</label>"
    ]

  defp slack_block(block),
    do: [
      "<div class=\"slack-block slack-unknown\"><code>",
      escape(inspect(block)),
      "</code></div>"
    ]

  defp slack_fields(nil), do: ""

  defp slack_fields(fields),
    do: ["<div class=\"slack-fields\">", Enum.map(fields, &slack_text/1), "</div>"]

  defp slack_text(%{"type" => "mrkdwn", "text" => text}),
    do: [
      "<div class=\"slack-text\">",
      SlackMarkdown.render(text),
      "</div>"
    ]

  defp slack_text(%{"text" => text}), do: ["<span class=\"slack-text\">", escape(text), "</span>"]

  defp slack_text(text) when is_binary(text),
    do: ["<span class=\"slack-text\">", escape(text), "</span>"]

  defp slack_text(_text), do: ""

  defp slack_element(%{"type" => "button"} = element) do
    label = get_in(element, ["text", "text"]) || "Button"

    # Slack opens `confirm` as a dialog after a click, never as message content.
    # This inert preview leaves it in the payload for native Slack inspection.
    [
      "<button class=\"slack-button",
      if(element["style"], do: [" ", escape(element["style"])], else: ""),
      "\" type=\"button\" disabled>",
      escape(label),
      if(element["url"], do: " ↗", else: ""),
      "</button>"
    ]
  end

  defp slack_element(%{"type" => "overflow", "options" => options}) do
    [
      "<details class=\"slack-overflow\"><summary aria-label=\"More actions\">···</summary><div class=\"slack-overflow-menu\">",
      Enum.map(options, fn option ->
        [
          "<button type=\"button\" disabled>",
          escape(get_in(option, ["text", "text"])),
          "</button>"
        ]
      end),
      "</div></details>"
    ]
  end

  defp slack_element(%{"type" => "plain_text_input"} = element) do
    ["<textarea disabled rows=\"3\">", escape(element["initial_value"] || ""), "</textarea>"]
  end

  defp slack_element(element),
    do: ["<code class=\"slack-element\">", escape(inspect(element)), "</code>"]

  defp card_lab_path(card_id, state_id),
    do: ["/card-lab/", segment(card_id), "/", segment(state_id)]

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
      lab_admission_progress(Map.get(snapshot, :admission_progress, [])),
      if(episodes == [] and Map.get(snapshot, :admission_progress, []) == [],
        do: "<p>Awaiting admission.</p>",
        else: ["<ul>", episodes, "</ul>"]
      ),
      "</aside></div>",
      "<form id=\"lab-composer\" phx-update=\"ignore\" class=\"composer\" method=\"post\" enctype=\"multipart/form-data\" action=\"/lab/",
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
          "Open Slack Card Lab first; walk every family and state, inspect confirmation copy and raw Block Kit, then leave state-scoped feedback without posting to Slack.",
          "Mention Responder in an approved test channel; confirm the reply stays in the exact thread.",
          "Request a task: confirm the host-owned offer card, then verify status, progress repaint, Stop, and idempotent button retries.",
          "React with configured Unicode and custom emoji; confirm one normalized reaction input and no bot-loop echo.",
          "Upload a bounded attachment and create an incident room; verify authenticated fetch, audience, topic, bookmarks, and cleanup."
        ],
        "/card-lab"
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

  def episode(%{episode: episode, trace: trace} = snapshot) do
    [
      CaseFile.render(%{
        episode: episode,
        case_file:
          Map.get(trace, :case_file, %{
            title: "Episode case file",
            messages: [],
            repository: nil,
            reply: nil,
            reply_status: nil
          })
      })
      |> Safe.to_iodata(),
      episode_operator_strip(trace),
      "<p class=\"episode-inspect-link\"><a class=\"button\" href=\"/episodes/",
      segment(episode.ref),
      "/requests\">Inspect model requests →</a><span>Instructions, messages, tools, candidates, and delivery</span></p>",
      "<section class=\"episode-metrics\" aria-label=\"Episode measurements\">",
      Enum.map(trace.metrics, &episode_metric/1),
      "</section>",
      accounting_summary(Map.get(snapshot, :accounting)),
      episode_stopped(trace.stopped),
      "<section class=\"episode-context\">",
      definition_list([
        {"Destination", episode.destination},
        {"Started", episode.created_at},
        {"Latest change", episode.updated_at}
      ]),
      "</section><section class=\"trace-shell\"><header class=\"trace-heading\"><div>",
      "<p class=\"eyebrow\">Execution trace</p><h2>What happened, in order</h2>",
      "<p>Durable host decisions, worker activity, and visible side effects. Open the request inspector for retained instructions, context, and results.</p>",
      episode_history_notice(Map.get(trace, :history)),
      "</div><div class=\"trace-stats\">",
      Enum.map(trace.stats, &trace_stat/1),
      "</div></header>",
      episode_chapters(trace.chapters),
      "</section>"
    ]
  end

  defp episode_operator_strip(trace) do
    source = Map.get(trace, :source)
    actions = Map.get(trace, :actions, [])
    review = Map.get(trace, :review, %{})

    if source || actions != [] || review[:at] do
      [
        "<section class=\"episode-actions\" aria-label=\"Episode actions\"><div class=\"episode-action-copy\">",
        episode_review_status(review),
        "</div><div class=\"episode-action-buttons\">",
        source_action(source),
        Enum.map(actions, &episode_action/1),
        "</div></section>"
      ]
    else
      ""
    end
  end

  defp episode_review_status(%{at: %DateTime{} = at, current: current} = review) do
    status = if current, do: "Current ending reviewed", else: "Earlier ending reviewed"

    [
      "<span class=\"eyebrow\">Operator review</span><strong>",
      escape(status),
      "</strong><small>",
      timestamp(at),
      if(review[:actor_ref], do: [" · ", escape(review.actor_ref)], else: ""),
      "</small>"
    ]
  end

  defp episode_review_status(%{awaiting: true}) do
    "<span class=\"eyebrow\">Operator review</span><strong>Awaiting review</strong><small>This exact ending has not been acknowledged.</small>"
  end

  defp episode_review_status(_review) do
    "<span class=\"eyebrow\">Source and recovery</span><strong>Episode controls</strong><small>Every mutation opens an explicit confirmation.</small>"
  end

  defp source_action(%{href: href, label: label, transport: transport}) do
    external = String.starts_with?(href, ["http://", "https://"])

    [
      "<a class=\"button secondary\" href=\"",
      escape(href),
      "\"",
      if(external, do: " target=\"_blank\" rel=\"noopener noreferrer\"", else: ""),
      ">",
      escape(label),
      " · ",
      escape(transport),
      "</a>"
    ]
  end

  defp source_action(_source), do: ""

  defp episode_action(action) do
    Components.action_button(action.href, action.label, action.tone)
  end

  defp episode_metric(metric) do
    [
      "<article class=\"episode-metric ",
      tone_class(metric.tone),
      "\"><span>",
      escape(metric.label),
      "</span><strong>",
      escape(metric.value),
      "</strong><small>",
      escape(metric.detail),
      "</small></article>"
    ]
  end

  defp episode_stopped(nil), do: ""

  defp episode_stopped(stopped) do
    [
      "<section class=\"episode-stop\" role=\"status\"><div class=\"stop-signal\" aria-hidden=\"true\">!</div><div>",
      "<p class=\"eyebrow\">Why it stopped</p><h2>",
      escape(stopped.headline),
      "</h2><p>",
      escape(stopped.reason),
      "</p>",
      attempted(stopped.attempted),
      "<div class=\"stop-action\"><span>Do this next</span><strong>",
      escape(stopped.action),
      "</strong>",
      if(stopped.href,
        do: ["<a class=\"button\" href=\"", escape(stopped.href), "\">Open recovery</a>"],
        else: ""
      ),
      "</div></div></section>"
    ]
  end

  defp attempted([]), do: ""

  defp attempted(items) do
    [
      "<div class=\"stop-attempted\"><span>Already attempted</span><ul>",
      Enum.map(items, &["<li>", escape(&1), "</li>"]),
      "</ul></div>"
    ]
  end

  defp episode_chapters([]) do
    "<p class=\"trace-empty\">No durable activity has been recorded for this episode yet.</p>"
  end

  defp episode_chapters(chapters) do
    chapters
    |> Enum.with_index(1)
    |> Enum.map(fn {chapter, index} ->
      [
        "<section class=\"trace-chapter\" data-chapter=\"",
        integer(index),
        "\"><header class=\"chapter-heading\"><span class=\"chapter-number\">",
        String.pad_leading(integer(index), 2, "0"),
        "</span><div><h3>",
        escape(chapter.title),
        "</h3><p>",
        escape(chapter.blurb),
        "</p></div><span class=\"chapter-span\">",
        escape(chapter.span || "sequence only"),
        "</span></header><div class=\"trace-rail\">",
        Enum.map(chapter.steps, &trace_step/1),
        "</div></section>"
      ]
    end)
  end

  defp trace_step(step) do
    [
      "<article id=\"",
      escape(step.id),
      "\" class=\"trace-step ",
      tone_class(step.tone),
      "\" data-stage=\"",
      escape(step.stage),
      "\" data-state=\"",
      escape(step.state),
      "\"><span class=\"trace-marker\" aria-hidden=\"true\"></span><div class=\"trace-card\">",
      "<header class=\"trace-card-head\"><div class=\"trace-labels\"><span class=\"trace-stage\">",
      escape(step.stage),
      "</span><span class=\"trace-state\">",
      escape(step.state),
      "</span></div><div class=\"trace-time\"><span>",
      timestamp(step.at),
      "</span>",
      trace_duration(step.duration_ms),
      "</div></header><h4>",
      trace_title(step),
      "</h4><p>",
      escape(step.summary || "No bounded summary was recorded."),
      "</p><div class=\"trace-byline\">",
      escape(step.actor),
      "</div>",
      trace_details(step.details),
      "</div></article>"
    ]
  end

  defp trace_title(%{href: href, title: title}) when is_binary(href),
    do: ["<a href=\"", escape(href), "\">", escape(title), "</a>"]

  defp trace_title(step), do: escape(step.title)

  defp trace_duration(nil), do: ""
  defp trace_duration(milliseconds), do: ["<span>", duration(milliseconds), "</span>"]

  defp trace_details([]), do: ""

  defp trace_details(details) do
    [
      "<details class=\"trace-details\"><summary>Inspect recorded details</summary><dl>",
      Enum.map(details, fn detail ->
        ["<dt>", escape(detail.label), "</dt><dd>", escape(detail.value), "</dd>"]
      end),
      "</dl></details>"
    ]
  end

  defp trace_stat(stat) do
    ["<span><strong>", escape(stat.value), "</strong>", escape(stat.label), "</span>"]
  end

  defp episode_history_notice(%{truncated: true, windows: windows}) do
    truncated = Enum.filter(windows, & &1.truncated)

    [
      "<p class=\"trace-notice\"><strong>Bounded history:</strong> ",
      truncated
      |> Enum.map(fn window ->
        [
          "latest ",
          integer(window.shown),
          " of ",
          integer(window.total),
          " ",
          escape(window.label)
        ]
      end)
      |> Enum.intersperse(" · "),
      ". Older rows remain durable but are outside this page.</p>"
    ]
  end

  defp episode_history_notice(_history), do: ""

  defp tone_class(:good), do: "tone-good"
  defp tone_class(:warn), do: "tone-warn"
  defp tone_class(:bad), do: "tone-bad"
  defp tone_class(_tone), do: "tone-neutral"

  def incidents(items, params \\ %{}) do
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
      search_form(
        "/incidents",
        "Title, room, repository or channel",
        params,
        ~w(requested ready blocked closed)
      ),
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

  def schedules(items, params \\ %{}) do
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
      search_form(
        "/schedules",
        "Title, repository or destination",
        params,
        ~w(active paused completed expired deleted)
      ),
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
      Components.action_button(
        "/actions/schedule/#{segment(schedule.ref)}/run-now",
        "Run now",
        :primary
      ),
      "<a href=\"/lab\">Replace in Conversation Lab…</a></div>",
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

  def subscriptions(items, params \\ %{}) do
    rows =
      Enum.map(items, fn item ->
        [
          "<tr><td><code>",
          escape(item.ref),
          "</code></td><td>",
          escape(item.source_kind || "any"),
          "</td><td>",
          escape(item.status),
          " / ",
          escape(item.resolution_kind || "waiting"),
          "</td><td>",
          timestamp(item.poll_after),
          "</td><td>",
          timestamp(item.deadline_at),
          "</td><td>",
          episode_link(item.episode_ref),
          "</td><td><code>",
          escape(item.matcher_digest),
          "</code></td><td><code>",
          escape(item.cursor_digest || "none"),
          "</code></td><td>",
          timestamp(item.last_observed_at),
          "</td></tr>"
        ]
      end)

    [
      workbench_intro(
        "External event subscriptions",
        "Inspect durable webhook-first waits, their polling fallback, hard deadline, cursor custody, and terminal resolution without exposing source payloads."
      ),
      search_form(
        "/subscriptions",
        "Subscription, source or episode",
        params,
        ~w(active resolved timed_out cancelled)
      ),
      table(
        [
          "Subscription",
          "Source",
          "State",
          "Poll fallback",
          "Deadline",
          "Episode",
          "Matcher digest",
          "Cursor digest",
          "Observed"
        ],
        rows
      )
    ]
  end

  def channels(items, params \\ %{}) do
    rows =
      Enum.map(items, fn item ->
        [
          "<tr><td><a href=\"/channels/",
          segment(item.workspace_ref),
          "/",
          segment(item.channel_ref),
          "\" title=\"",
          escape(item.channel_ref),
          "\">",
          escape(SlackNames.name(item.workspace_ref, item.channel_ref)),
          "</a><br><span class=\"muted\" title=\"",
          escape(item.workspace_ref),
          "\">",
          escape(SlackNames.name(item.workspace_ref, item.workspace_ref)),
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
      search_form("/channels", "Channel, workspace or repository", params),
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
        {"Workspace", {:safe, slack_reference(channel.workspace_ref, channel.workspace_ref)}},
        {"Channel", {:safe, slack_reference(channel.workspace_ref, channel.channel_ref)}},
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

  def repositories(items, params \\ %{}) do
    rows =
      Enum.map(items, fn item ->
        [
          "<article class=\"repository-card\"><header class=\"repository-heading\"><h2>",
          escape(item.ref),
          "</h2><a href=\"/episodes?repository=",
          segment(item.ref),
          "\">View requests →</a></header>",
          "<div class=\"repository-summary\"><span><strong>",
          integer(item.sessions),
          "</strong> work sessions</span><span><strong>",
          integer(item.channels),
          "</strong> connected channels</span><span><strong>",
          integer(item.schedules),
          "</strong> schedules</span><span><strong>",
          integer(item.publications),
          "</strong> PR workflows</span></div>",
          "<p class=\"repository-revision\">",
          repository_revision(item.freshness),
          "</p>",
          "<details><summary>Code revision & access configuration</summary><p>Access: ",
          escape(policy_summary(item.configured)),
          " · <a href=\"/configuration\">Inspect configuration</a></p>",
          freshness_detail(item.freshness),
          "</details><details><summary>Worker connections</summary>",
          worker_list(item.workers),
          "<p><a href=\"/configuration\">Inspect worker configuration →</a></p></details></article>"
        ]
      end)

    [
      workbench_intro(
        "Where Responder can work",
        "Connected repositories, the work they receive, and the code revision last used. Open a request to inspect the actual changes and model activity."
      ),
      search_form("/repositories", "Repository name", params),
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
          number(row.tokens),
          "</td><td>",
          Pricing.amount(row),
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
        "Compare speed and reliability",
        "See which model handled each type of work and where it spent time. Compare execution time and extra attempts to correct an invalid result before changing model routing in Configuration. This view includes accepted work with a linked input; it is not an answer-quality score or a complete failure rate."
      ),
      "<p class=\"page-description\">≈ includes API-equivalent estimates, not subscription charges. <a href=\"/usage#cost-method\">How cost is calculated →</a></p>",
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
          "Cost (USD)",
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
      "</td><td>",
      Components.action_button("/actions/memory/#{segment(item.ref)}/forget", "Forget", :danger),
      "</td></tr>"
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
      "</td><td><div class=\"action-controls\">",
      Components.action_button(
        "/actions/behavior/#{segment(item.ref)}/#{next}",
        if(next == :active, do: "Enable", else: "Disable")
      ),
      Components.action_button(
        "/actions/behavior/#{segment(item.ref)}/deleted",
        "Delete",
        :danger
      ),
      "</div></td></tr>"
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
      "</td><td><div class=\"action-controls\">",
      Components.action_button(
        "/actions/schedule/#{segment(item.ref)}/#{next}",
        if(next == :active, do: "Resume", else: "Pause")
      ),
      Components.action_button(
        "/actions/schedule/#{segment(item.ref)}/run-now",
        "Run now",
        :primary
      ),
      Components.action_button(
        "/actions/schedule/#{segment(item.ref)}/deleted",
        "Delete",
        :danger
      ),
      "</div></td></tr>"
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
          "</strong> attempts</span>",
          if(FailurePage.manual_repair?(row),
            do: "<span class=\"failure-repair-needed\">Needs developer repair</span>",
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
      {"emisar", "Approvals"}
    ]

    stats =
      [{"Failures", length(rows)}] ++
        Enum.filter([{"Affected requests", requests}], fn {_, count} -> count > 0 end) ++
        Enum.flat_map(types, fn {kind, label} ->
          case Map.get(counts, kind, 0) do
            0 -> []
            count -> [{label, count}]
          end
        end)

    [
      "<dl class=\"failure-summary\" aria-label=\"Summary of listed failures\">",
      Enum.map(stats, fn {label, count} ->
        ["<div><dt>", escape(label), "</dt><dd>", integer(count), "</dd></div>"]
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
      if(FailurePage.manual_repair?(row), do: "Retry cleanup", else: recovery_label(row.kind)),
      :primary
    )
  end

  defp failure_recovery_action(_row), do: []

  def workspaces([]),
    do: "<section><h2>Workspaces</h2><p class=\"empty\">No durable workspaces.</p></section>"

  def workspaces(rows) do
    body =
      Enum.map(rows, fn row ->
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
          "<tr><td title=\"",
          escape(row.ref),
          "\"><strong>",
          escape(Map.get(row, :repository) || "Repository not recorded"),
          "</strong>",
          if(row[:episode_ref],
            do: [
              "<br><a class=\"workspace-request-title\" href=\"/episodes/",
              segment(row.episode_ref),
              "\">",
              workspace_request_label(row),
              "</a>"
            ],
            else: []
          ),
          "</td><td>",
          escape(workspace_status(row.status)),
          "</td><td>",
          "<span title=\"",
          escape(row.summary),
          "\">",
          escape(workspace_reason(row)),
          "</span>",
          "</td><td>",
          escape(Components.label(row.state)),
          "</td><td>",
          readable_time(row.updated_at),
          "</td><td>",
          action,
          "</td></tr>"
        ]
      end)

    [
      "<section><h2>Repository working copies</h2><p>These are the checkout directories used by tasks, not Slack workspaces. Responder keeps unfinished or unmerged work safe. Resume interrupted cleanup below; discarding unmerged commits always requires confirmation.</p>",
      table(
        ["Working copy", "Lifecycle", "What happens next", "Request", "Updated", "Action"],
        body
      ),
      "</section>"
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

  def decisions(rows) do
    body =
      Enum.map(rows, fn row ->
        [
          "<tr><td title=\"",
          escape(row.ref),
          "\"><strong>",
          escape(decision_label(row.state)),
          "</strong>",
          if(row.status == :superseded,
            do: "<br><small>Replaced by a newer message revision</small>",
            else: []
          ),
          "</td><td>",
          escape(decision_source(row.summary)),
          "</td><td>",
          readable_time(row.updated_at),
          "</td><td>",
          if(row[:input_id],
            do: [
              "<a href=\"/admission/",
              segment(row.input_id),
              "\">Inspect message & decision →</a>"
            ],
            else: "Input record unavailable"
          ),
          "</td></tr>"
        ]
      end)

    [
      workbench_intro(
        "How messages were routed",
        "For each incoming message, Responder chooses a direct reply, a reaction, work on a new or existing request, or no response. Inspect a decision to see the actual message, classifier input and saved result. Latest 100 decisions."
      ),
      if(rows == [],
        do:
          "<p class=\"empty\">No routing decisions yet. Send a message in Conversation Lab to follow one end to end.</p>",
        else: table(["Decision", "Source", "When", "Inspect"], body)
      )
    ]
  end

  defp decision_label(:start_episode), do: "Start work"
  defp decision_label(:join_episode), do: "Continue existing work"
  defp decision_label(:reply), do: "Reply directly"
  defp decision_label(:react), do: "React to the message"
  defp decision_label(:ignore), do: "No response needed"
  defp decision_label(other), do: Components.label(other)

  defp decision_source("control_plane"), do: "Conversation Lab"
  defp decision_source(source), do: String.capitalize(to_string(source))

  def configuration(%{rows: rows, grants: grants, source: source}) do
    configuration_rows =
      Enum.map(rows, fn row ->
        help = ConfigurationHelp.setting(row.key)

        [
          "<section class=\"configuration-setting\" data-setting=\"",
          escape(row.key),
          "\"><div class=\"configuration-setting-value\"><h3>",
          escape(help.title),
          "</h3><code>",
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
      end)

    grant_rows =
      Enum.map(grants, fn grant ->
        [
          "<tr><td>",
          escape(grant.kind),
          "<p class=\"configuration-grant-help\">",
          escape(ConfigurationHelp.grant(grant.kind)),
          "</p>",
          "</td><td><code>",
          escape(grant.name),
          "</code></td><td><code>",
          escape(grant.source),
          "</code></td></tr>"
        ]
      end)

    [
      "<div class=\"configuration-guide\"><h2>Effective host configuration</h2><p>What this Responder is configured to do, and what each setting changes.</p><p>Loaded from <code>",
      escape(source),
      "</code>.</p><div class=\"configuration-change-note\"><strong>How to change these settings</strong><p>This page is read-only. Edit the host YAML (or application environment in a component setup), validate it, then restart Responder through the normal deployment workflow. Refreshing this page does not reload the file or change running work.</p><p>Configured means the component has configuration, not that its connection or workers are healthy. Defaults below describe the v1 loader; example YAML values are not necessarily defaults. Credentials, URLs, callback values and raw policy documents remain private.</p></div></div><div class=\"configuration-settings\" aria-label=\"Effective values and explanations\">",
      configuration_rows,
      "</div><section><h2>MCP and tool grants</h2><p class=\"configuration-grants-note\">This is an inventory of configured names, not a live tool-health check. Listing a tool does not grant permission to use it.</p>",
      table(["Grant kind", "Capability or tool", "Source"], grant_rows),
      "</section><p class=\"muted\">Repository-specific policy topology and serving-worker revisions are shown under <a href=\"/repositories\">Repositories</a>.</p>"
    ]
  end

  def configuration(rows), do: generic("Effective host configuration", rows)

  def usage(snapshot),
    do: UsagePage.render(snapshot)

  defp accounting_summary(nil), do: ""

  defp accounting_summary(totals) do
    [
      "<section class=\"case-accounting\" aria-label=\"Execution cost\"><div><span>Cost (USD)</span><strong>",
      Pricing.amount(totals),
      "</strong></div><p>",
      integer(totals.costed),
      " reported · ",
      integer(Map.get(totals, :estimated, 0)),
      " estimated / ",
      integer(totals.attempts),
      " execution requests · ",
      escape(coverage(totals.usage_measured, totals.attempts)),
      " with token telemetry<br><small>Includes admission and unsuccessful executions linked to this episode. Child-task cost and historical missing telemetry are not included. <a href=\"/usage#cost-method\">Cost method and estimate limits</a>.</small></p></section>"
    ]
  end

  def css, do: base_css() <> @native_slack_css

  defp base_css do
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
    .episode-hero{align-items:end;background:linear-gradient(118deg,#172128 0,#0e1217 62%,#17200f 100%);border:1px solid #33404b;border-radius:20px;display:flex;gap:2rem;justify-content:space-between;overflow:hidden;padding:clamp(1.3rem,4vw,2.4rem);position:relative}.episode-hero:after{background:linear-gradient(90deg,transparent,var(--accent));bottom:0;content:"";height:2px;left:0;position:absolute;width:100%}.episode-hero h2{font-size:clamp(1.45rem,3vw,2.3rem);margin:.15rem 0}.episode-ref{color:var(--muted);margin:.7rem 0 0;overflow-wrap:anywhere}.episode-state{border-left:2px solid var(--line);display:grid;min-width:190px;padding:.2rem 0 .2rem 1rem}.episode-state span,.episode-state small{color:var(--muted);font-size:.7rem;font-weight:800;letter-spacing:.08em;text-transform:uppercase}.episode-state strong{font-size:1.25rem;margin:.15rem 0}.episode-state.tone-good{border-color:var(--accent)}.episode-state.tone-warn{border-color:var(--warning)}.episode-state.tone-bad{border-color:var(--danger)}
    .episode-actions{align-items:center;background:#11171c;border:1px solid var(--line);border-radius:14px;display:flex;gap:1rem;justify-content:space-between;margin:1rem 0;padding:.85rem 1rem}.episode-action-copy{display:grid;gap:.1rem}.episode-action-copy strong{font-size:.92rem}.episode-action-copy small{color:var(--muted)}.episode-action-buttons{display:flex;flex-wrap:wrap;gap:.5rem;justify-content:flex-end}.button.secondary{background:#202a32}.button.danger{background:#5c2927}.episode-metrics{display:grid;gap:.65rem;grid-template-columns:repeat(auto-fit,minmax(125px,1fr));margin:1rem 0}.episode-metric{background:#0e1318;border:1px solid var(--line);border-radius:11px;display:grid;min-height:112px;padding:.85rem}.episode-metric>span{color:var(--muted);font-size:.66rem;font-weight:900;letter-spacing:.12em;text-transform:uppercase}.episode-metric strong{align-self:end;font-size:1.3rem;line-height:1.15;margin:.65rem 0 .25rem;overflow-wrap:anywhere}.episode-metric small{color:#89949f}.episode-metric.tone-good{border-top-color:#6c8e2e}.episode-metric.tone-warn{border-top-color:#8d6c25}.episode-metric.tone-bad{border-top-color:#994743}.episode-context{background:#0c1014;border:1px solid var(--line);border-radius:12px;margin:1rem 0;padding:.15rem 1rem}.episode-context dl{font-size:.78rem;grid-template-columns:max-content minmax(0,1fr)}
    .episode-stop{background:linear-gradient(120deg,#2a1717,#151114);border:1px solid #713c3b;border-radius:16px;display:grid;gap:1.1rem;grid-template-columns:46px minmax(0,1fr);margin:1rem 0;padding:1.15rem}.stop-signal{align-items:center;background:var(--danger);border-radius:50%;color:#1b0909;display:flex;font-size:1.35rem;font-weight:950;height:42px;justify-content:center;width:42px}.episode-stop h2{font-size:1.25rem;margin:.1rem 0}.episode-stop p{color:#dbbfbd;margin:.35rem 0}.stop-attempted{border-top:1px solid #563130;margin-top:.8rem;padding-top:.7rem}.stop-attempted>span,.stop-action>span{color:#bf9693;display:block;font-size:.67rem;font-weight:900;letter-spacing:.1em;text-transform:uppercase}.stop-attempted ul{display:flex;flex-wrap:wrap;gap:.4rem;list-style:none;margin:.45rem 0 0;padding:0}.stop-attempted li{background:#321d1e;border:1px solid #603333;border-radius:999px;color:#f0cdca;font-size:.76rem;padding:.18rem .55rem}.stop-action{align-items:center;display:grid;gap:.15rem;grid-template-columns:minmax(0,1fr) auto;margin-top:.85rem}.stop-action span,.stop-action strong{grid-column:1}.stop-action .button{grid-column:2;grid-row:1/3}
    .trace-shell{background:#0b0f13;border:1px solid var(--line);border-radius:18px;margin-top:1.1rem;overflow:hidden}.trace-heading{align-items:flex-start;background:linear-gradient(110deg,#151c23,#0d1115);border-bottom:1px solid var(--line);display:flex;gap:2rem;justify-content:space-between;padding:1.4rem}.trace-heading h2{font-size:1.45rem;margin:.1rem 0}.trace-heading p:last-child{color:var(--muted);margin:.3rem 0;max-width:68ch}.trace-stats{display:flex;gap:.45rem}.trace-stats>span{background:#0a0e12;border:1px solid var(--line);border-radius:8px;color:var(--muted);display:grid;font-size:.62rem;letter-spacing:.08em;min-width:66px;padding:.45rem;text-align:center;text-transform:uppercase}.trace-stats strong{color:var(--text);font-size:1rem}.trace-chapter{padding:0 1.4rem}.trace-chapter+.trace-chapter{border-top:1px solid var(--line)}.chapter-heading{align-items:center;display:grid;gap:1rem;grid-template-columns:42px minmax(0,1fr) auto;padding:1.3rem 0 .8rem}.chapter-number{color:var(--cyan);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.78rem;font-weight:900;letter-spacing:.12em}.chapter-heading h3{font-size:1.15rem;margin:0}.chapter-heading p{color:var(--muted);font-size:.82rem;margin:.15rem 0}.chapter-span{color:var(--muted);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.7rem}
    .trace-rail{padding:0 0 1.25rem 20px;position:relative}.trace-rail:before{background:#33414c;bottom:1.7rem;content:"";left:26px;position:absolute;top:.55rem;width:1px}.trace-step{display:grid;gap:1rem;grid-template-columns:14px minmax(0,1fr);position:relative}.trace-step+.trace-step{margin-top:.7rem}.trace-marker{background:#6f7c87;border:3px solid #0b0f13;border-radius:50%;height:13px;margin-top:1.1rem;position:relative;width:13px;z-index:1}.trace-step.tone-good .trace-marker{background:var(--accent)}.trace-step.tone-warn .trace-marker{background:var(--warning)}.trace-step.tone-bad .trace-marker{background:var(--danger)}.trace-card{background:#11171d;border:1px solid #293640;border-radius:11px;padding:.85rem 1rem}.trace-step.tone-good .trace-card{border-left-color:#6c8e2e}.trace-step.tone-warn .trace-card{border-left-color:#8d6c25}.trace-step.tone-bad .trace-card{border-left-color:#994743}.trace-card-head{align-items:center;display:flex;gap:1rem;justify-content:space-between}.trace-labels,.trace-time{align-items:center;display:flex;flex-wrap:wrap;gap:.4rem}.trace-stage,.trace-state{border:1px solid #3b4853;border-radius:999px;color:#aab6c0;font-size:.62rem;font-weight:900;letter-spacing:.08em;padding:.15rem .45rem;text-transform:uppercase}.trace-state{border-color:#365364;color:var(--cyan)}.trace-time{color:#788590;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.66rem}.trace-card h4{font-size:1rem;margin:.55rem 0 .15rem}.trace-card h4 a{color:var(--text)}.trace-card>p{color:#bdc6ce;margin:.2rem 0}.trace-byline{color:#7f8c97;font-size:.68rem;font-weight:800;letter-spacing:.08em;margin-top:.5rem;text-transform:uppercase}.trace-details{border-top:1px solid #293640;margin-top:.7rem;padding-top:.55rem}.trace-details summary{color:#9facb7;cursor:pointer;font-size:.7rem;font-weight:800;letter-spacing:.05em}.trace-details dl{font-size:.74rem;grid-template-columns:minmax(100px,max-content) minmax(0,1fr);margin:.65rem 0 .15rem}.trace-details dd{color:#d2dae1;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}.trace-empty{color:var(--muted);padding:1.4rem}.tone-good .trace-state{border-color:#536d29;color:var(--accent)}.tone-warn .trace-state{border-color:#715a2a;color:var(--warning)}.tone-bad .trace-state{border-color:#743a39;color:var(--danger)}
    .card-lab-hero{align-items:end;background:linear-gradient(125deg,#16252b 0,#101419 58%,#1d2411 100%);border:1px solid #3b4a43;border-radius:20px;display:flex;gap:2rem;justify-content:space-between;overflow:hidden;padding:clamp(1.3rem,4vw,2.4rem);position:relative}.card-lab-hero:after{background:linear-gradient(90deg,var(--cyan),var(--accent));bottom:0;content:"";height:2px;left:0;position:absolute;width:100%}.card-lab-hero h2{font-size:clamp(1.5rem,3vw,2.35rem);margin:.1rem 0}.card-lab-hero p:last-child{color:#b9c5cb;max-width:74ch}.card-lab-totals{display:grid;grid-template-columns:auto auto;line-height:1;min-width:150px}.card-lab-totals strong{color:var(--accent);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:1.7rem;padding:.25rem .6rem;text-align:right}.card-lab-totals span{color:var(--muted);font-size:.68rem;font-weight:900;letter-spacing:.09em;padding:.65rem 0;text-transform:uppercase}
    .card-lab-shell{background:#0b0f13;border:1px solid var(--line);border-radius:18px;display:grid;grid-template-columns:190px minmax(0,1fr) 270px;margin-top:1rem;min-height:760px;overflow:hidden}.card-lab-catalog{background:#090c10;border-right:1px solid var(--line)}.card-lab-panel-head{border-bottom:1px solid var(--line);display:grid;padding:1rem}.card-lab-panel-head span{font-size:.74rem;font-weight:900;letter-spacing:.12em;text-transform:uppercase}.card-lab-panel-head small{color:var(--muted)}.card-lab-catalog ul{list-style:none;margin:0;padding:0}.card-lab-catalog li{border-bottom:1px solid #1f272e}.card-lab-catalog li.selected{background:#172026;box-shadow:inset 3px 0 var(--accent)}.card-lab-catalog a{display:grid;padding:.75rem .85rem;text-decoration:none}.card-lab-catalog a span{color:#e9edf0;font-size:.82rem;font-weight:750}.card-lab-catalog a small{color:#74818b;font-size:.64rem;letter-spacing:.03em;margin-top:.15rem;text-transform:uppercase}.card-lab-stage{min-width:0;padding:1rem}.card-lab-stage-head{align-items:start;display:flex;gap:1rem;justify-content:space-between}.card-lab-stage-head h2{font-size:1.35rem;margin:.05rem 0}.card-lab-stage-head p:last-child{color:var(--muted);font-size:.8rem;margin:.25rem 0;max-width:58ch}.card-lab-state-count{border:1px solid #3b4a54;border-radius:999px;color:var(--cyan);font-size:.65rem;font-weight:900;padding:.25rem .55rem;white-space:nowrap}.card-lab-state-tabs{display:flex;flex-wrap:nowrap;gap:.35rem;margin:.9rem -1rem 0;overflow:auto;padding:.7rem 1rem}.card-lab-state-tabs a{background:#13191e;border:1px solid #2d3942;border-radius:999px;color:#aab5bd;font-size:.69rem;padding:.28rem .55rem;text-decoration:none;white-space:nowrap}.card-lab-state-tabs a[aria-current=page]{background:#28351c;border-color:#5c7532;color:var(--accent)}.card-lab-current{align-items:start;border-left:2px solid var(--cyan);display:flex;gap:1rem;justify-content:space-between;margin:.4rem 0 1rem;padding:.2rem 0 .2rem .75rem}.card-lab-current span{color:var(--muted);font-size:.62rem;font-weight:900;letter-spacing:.09em;text-transform:uppercase}.card-lab-current h3{font-size:1.02rem;margin:.05rem 0}.card-lab-current p{color:#aab4bc;font-size:.76rem;margin:.15rem 0}.card-lab-current code{color:#71808b;font-size:.65rem;max-width:48%;overflow-wrap:anywhere;text-align:right}
    .slack-canvas{background:#f8f8f8;border:1px solid #d5d5d5;border-radius:12px;color:#1d1c1d;min-height:260px;overflow:hidden}.slack-chrome{align-items:center;background:#3f0e40;color:#fff;display:flex;font-size:.75rem;gap:.8rem;padding:.65rem .8rem}.slack-chrome small{margin-left:auto;opacity:.65}.slack-dots{display:flex;gap:.3rem}.slack-dots i{background:#eb5a46;border-radius:50%;display:block;height:8px;width:8px}.slack-dots i:nth-child(2){background:#f5bf4f}.slack-dots i:nth-child(3){background:#57c353}.slack-message-preview{display:grid;gap:.65rem;grid-template-columns:36px minmax(0,1fr);padding:1rem}.slack-avatar{align-items:center;background:linear-gradient(145deg,#1264a3,#2eb67d);border-radius:8px;color:#fff;display:flex;font-size:1rem;font-weight:900;height:36px;justify-content:center;width:36px}.slack-message-content>header,.slack-feedback-list header{align-items:center;background:none;border:0;display:flex;gap:.4rem;padding:0;position:static}.slack-message-content>header span{background:#e8e8e8;border-radius:3px;color:#5b5b5b;font-size:.58rem;font-weight:800;padding:.05rem .25rem}.slack-message-content>header time{color:#777;font-size:.68rem}.slack-block{margin:.45rem 0}.slack-text,.slack-markdown{display:block;font-size:.86rem;overflow-wrap:anywhere;white-space:pre-wrap}.slack-section{align-items:start;display:flex;gap:.75rem;justify-content:space-between}.slack-section aside{flex:0 0 auto}.slack-header{font-size:1.15rem;font-weight:900}.slack-context{color:#616061;display:flex;flex-wrap:wrap;font-size:.72rem;gap:.4rem}.slack-divider{border:0;border-top:1px solid #ddd;margin:.7rem 0}.slack-actions{display:flex;flex-wrap:wrap;gap:.45rem}.slack-button{background:#fff;border:1px solid #b7b7b7;border-radius:4px;color:#1d1c1d;font-size:.73rem;padding:.35rem .6rem}.slack-button.primary{background:#007a5a;border-color:#007a5a;color:#fff}.slack-button.danger{color:#e01e5a}.slack-button:disabled{cursor:default;opacity:1}.slack-overflow{border:1px solid #b7b7b7;border-radius:4px;font-size:.7rem;padding:.37rem .55rem}.slack-fields{display:grid;gap:.3rem;grid-template-columns:repeat(2,minmax(0,1fr));margin-top:.4rem}.slack-input{display:grid;gap:.3rem;font-weight:700}.slack-input textarea{border:1px solid #aaa;border-radius:4px;color:#333;padding:.45rem;resize:none;width:100%}.slack-fallback{background:#eee;border-top:1px solid #d6d6d6;display:grid;font-size:.65rem;padding:.5rem .8rem}.slack-fallback span{color:#666;overflow-wrap:anywhere}.thread-status-canvas{padding:1rem}.slack-thread-head{align-items:center;display:flex;gap:.6rem}.slack-thread-head div{display:grid}.slack-thread-head small{color:#777;font-size:.65rem}.slack-thread-status{align-items:center;background:#fff;border:1px solid #ddd;border-radius:6px;display:flex;font-size:.75rem;gap:.45rem;margin:1rem 0 0 2.8rem;padding:.55rem .7rem}.slack-thread-status.clear{color:#777}.status-pulse{background:#2eb67d;border-radius:50%;height:8px;width:8px}.clear .status-pulse{background:#aaa}
    .card-lab-json{background:#090d11;border:1px solid var(--line);border-radius:10px;margin-top:.8rem}.card-lab-json summary{color:#9eabb5;cursor:pointer;font-size:.72rem;font-weight:800;letter-spacing:.06em;padding:.65rem .8rem;text-transform:uppercase}.card-lab-json pre{border-top:1px solid var(--line);color:#c8d8e3;font-size:.68rem;margin:0;max-height:520px;overflow:auto;padding:.8rem;white-space:pre-wrap}.card-lab-inspector{background:#0e1317;border-left:1px solid var(--line);padding:1rem}.card-lab-inspector>section+section{border-top:1px solid var(--line);margin-top:1.25rem;padding-top:1.25rem}.card-lab-inspector h2{font-size:1rem;margin:.1rem 0}.card-lab-inspector>section>p:not(.eyebrow){color:#98a4ad;font-size:.75rem}.card-lab-transitions{display:grid;gap:.45rem;margin-top:.7rem}.card-lab-transitions form{margin:0}.card-lab-transitions button{align-items:center;background:#172128;border:1px solid #354550;color:#dce6eb;display:flex;justify-content:space-between;text-align:left;width:100%}.card-lab-transitions button small{color:var(--cyan);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:.61rem}.card-lab-empty{color:#788690;font-size:.72rem}.card-lab-feedback-form{display:grid;gap:.7rem}.card-lab-feedback-form fieldset{border:0;display:flex;flex-wrap:wrap;gap:.35rem;margin:0;padding:0}.card-lab-feedback-form legend,.card-lab-feedback-form>label{color:#aeb8c0;font-size:.7rem;font-weight:800;margin-bottom:.35rem;text-transform:uppercase}.card-lab-feedback-form fieldset label{background:#171e23;border:1px solid #303c45;border-radius:999px;font-size:.68rem;padding:.22rem .4rem}.card-lab-feedback-form textarea{background:#080c0f;border:1px solid #3a4652;border-radius:8px;color:var(--text);font:inherit;margin-top:.35rem;padding:.6rem;resize:vertical;width:100%}.card-lab-feedback-list{display:grid;gap:.5rem;margin-top:1rem}.card-lab-feedback-list article{background:#11181d;border:1px solid #2d3942;border-left:2px solid var(--cyan);border-radius:7px;padding:.6rem}.card-lab-feedback-list article[data-verdict=needs_work]{border-left-color:var(--warning)}.card-lab-feedback-list article[data-verdict=approved]{border-left-color:var(--accent)}.card-lab-feedback-list article header{align-items:center;background:none;border:0;display:flex;justify-content:space-between;padding:0;position:static}.card-lab-feedback-list article strong{font-size:.66rem;text-transform:uppercase}.card-lab-feedback-list article time,.card-lab-feedback-list article small{color:#74818b;font-size:.59rem}.card-lab-feedback-list article p{font-size:.75rem;margin:.35rem 0;white-space:pre-wrap}
    @media(max-width:980px){.card-lab-shell{grid-template-columns:160px minmax(0,1fr)}.card-lab-inspector{border-left:0;border-top:1px solid var(--line);grid-column:1/-1;display:grid;gap:1.5rem;grid-template-columns:1fr 1fr}.card-lab-inspector>section+section{border-left:1px solid var(--line);border-top:0;margin:0;padding:0 0 0 1.5rem}}
    @media(max-width:760px){header,main{padding-left:1rem;padding-right:1rem}.lab-hero,.lab-heading,.episode-hero,.episode-actions,.trace-heading,.card-lab-hero{align-items:stretch;flex-direction:column}.episode-action-buttons{justify-content:flex-start}.lab-stream{grid-template-columns:1fr}.custody-strip{border-left:0;border-top:1px solid var(--line)}.message{max-width:96%}.composer-actions{align-items:stretch;flex-direction:column}.journey-grid{grid-template-columns:1fr}.search-form{grid-template-columns:1fr}.episode-state{min-width:0}.trace-stats{align-self:stretch}.trace-stats>span{flex:1}.chapter-heading{align-items:start;grid-template-columns:32px minmax(0,1fr)}.chapter-span{grid-column:2}.trace-chapter{padding:0 .85rem}.trace-rail{padding-left:10px}.trace-rail:before{left:16px}.trace-card-head{align-items:flex-start;flex-direction:column}.stop-action{grid-template-columns:1fr}.stop-action .button{grid-column:1;grid-row:auto;margin-top:.6rem;text-align:center}.card-lab-shell{display:block}.card-lab-catalog{border-bottom:1px solid var(--line);border-right:0;max-height:230px;overflow:auto}.card-lab-inspector{display:block}.card-lab-inspector>section+section{border-left:0;border-top:1px solid var(--line);margin-top:1.25rem;padding:1.25rem 0 0}.card-lab-current{display:grid}.card-lab-current code{max-width:none;text-align:left}.slack-fields{grid-template-columns:1fr}}
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
      nil ->
        "Before admission"

      ref ->
        [
          "<a title=\"",
          escape(ref),
          "\" href=\"/episodes/",
          segment(ref),
          "\">",
          escape(Map.get(row, :request_title) || "Open request"),
          " →</a>"
        ]
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

  defp workbench_intro(title, description) do
    [
      "<section class=\"page-description\"><h2>",
      escape(title),
      "</h2><p>",
      escape(description),
      "</p></section>"
    ]
  end

  defp search_form(path, placeholder, params, statuses \\ []) do
    params = UsageProjection.link_params(params)

    [
      "<form class=\"search-form\" method=\"get\" action=\"",
      escape(path),
      "\"><div class=\"filter-field filter-search\"><label for=\"operator-search\">Search</label><input type=\"search\" id=\"operator-search\" name=\"q\" maxlength=\"200\" value=\"",
      escape(params["q"] || ""),
      "\" placeholder=\"",
      escape(placeholder),
      "\"></div>",
      if(statuses != [],
        do: [
          "<div class=\"filter-field\"><label for=\"operator-status\">Status</label><select id=\"operator-status\" name=\"status\"><option value=\"\">All statuses</option>",
          Enum.map(statuses, fn status ->
            [
              "<option value=\"",
              escape(status),
              "\"",
              if(params["status"] == status, do: " selected", else: ""),
              ">",
              escape(Components.label(status)),
              "</option>"
            ]
          end),
          "</select></div>"
        ],
        else: []
      ),
      "<button class=\"ui-button primary\" type=\"submit\">Apply filters</button>",
      if(params["q"] not in [nil, ""] or params["status"] in statuses,
        do: ["<a class=\"ui-button secondary\" href=\"", escape(path), "\">Clear filters</a>"],
        else: []
      ),
      "</form>"
    ]
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

  defp slack_reference(workspace, ref),
    do: [
      "<span title=\"",
      escape(ref),
      "\">",
      escape(SlackNames.name(workspace, ref)),
      "</span>"
    ]

  defp workspace_status(:active), do: "In use"
  defp workspace_status(:grace), do: "Kept for follow-up"
  defp workspace_status(:retained), do: "Changes preserved"
  defp workspace_status(:discarded), do: "Removed safely"
  defp workspace_status(:blocked), do: "Cleanup needs attention"
  defp workspace_status(_), do: "Cleanup in progress"

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

  defp repository_revision(nil), do: "No code revision recorded yet."

  defp repository_revision(freshness),
    do: [
      "Last used commit <code title=\"",
      escape(freshness.resolved_revision),
      "\">",
      escape(String.slice(freshness.resolved_revision || "unknown", 0, 8)),
      "</code> · fetched ",
      readable_time(freshness.fetched_at),
      ". This is the saved execution snapshot, not a live Git check."
    ]

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
      "<p class=\"empty\">No fleet worker is reporting this repository here. A configured local development worker is not listed in the fleet.</p>"

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

  defp coverage(_measured, 0), do: "0 of 0"
  defp coverage(measured, attempts), do: "#{measured} of #{attempts}"

  defp duration(nil), do: "unmeasured"

  defp duration(milliseconds),
    do: :erlang.float_to_binary(milliseconds / 1_000, decimals: 2) <> " s"

  defp integer(value) when is_integer(value), do: Integer.to_string(value)
  defp integer(value), do: to_string(value)

  defp number(value), do: value |> integer() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")

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
