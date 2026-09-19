defmodule Ryker.ControlPlane.HTML do
  @moduledoc false

  alias Phoenix.HTML.Safe

  alias Ryker.ControlPlane.{
    Card,
    CodeEditingSetup,
    Components,
    ConfigurationGuide,
    ConfigurationHelp,
    ConversationLab,
    FailurePage,
    FindingsPage,
    Layouts,
    MemoryPage,
    SlackMarkdown,
    SlackNames,
    SubscriptionPresentation,
    SubscriptionsPage,
    UsagePage,
    UsageProjection
  }

  # The title and description are the shell's header; the body owns the rest.
  @spec page(String.t(), String.t() | nil, iodata()) :: binary()
  def page(title, description, body) do
    %{__changed__: nil, title: title, description: description, body: IO.iodata_to_binary(body)}
    |> Layouts.static()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  # The one body a missing page, record or action renders under the shell's
  # "Not found" title, on the live shell and the static one alike: it says the
  # thing is missing and offers a way back, never an empty list that would read
  # as the record's state.
  @spec not_found(String.t()) :: iodata()
  def not_found(subject) do
    [
      "<section class=\"document-unavailable\"><p>This ",
      escape(String.downcase(subject)),
      " does not exist or is no longer available. Check the link, or start again from Activity.</p>",
      "<a class=\"ui-button secondary\" href=\"/\">Back to activity</a></section>"
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

  @incident_statuses ~w(requested ready blocked closed)

  # One comparison table: the room's title over its exact reference, its
  # status as a dot and a word, and the linked publication's state the same
  # way. The shell owns the title and description.
  def incidents(items, params \\ %{}) do
    rows =
      Enum.map(items, fn item ->
        {status, tone} = incident_status(item.status)

        [
          [
            "<a href=\"/incident-rooms/",
            segment(item.ref),
            "\">",
            escape(item.title),
            "</a><span class=\"row-secondary\"><code>",
            escape(item.ref),
            "</code></span>"
          ],
          Components.status(status, tone),
          escape(item.repository_ref),
          escape(channel_label(item.workspace_ref, item.channel_ref)),
          publication_status(item.publication_status),
          readable_time(item.updated_at)
        ]
      end)

    [
      "<div class=\"incident-rooms-page\">",
      search_form(
        "/incident-rooms",
        "Title, room, repository or channel",
        params,
        @incident_statuses
      ),
      cond do
        rows != [] ->
          [
            result_count(length(rows), "incident room", "incident rooms"),
            data_table(
              ["Incident room", "Status", "Repository", "Channel", "Publication", "Updated"],
              rows
            )
          ]

        filtered?(params, @incident_statuses) ->
          empty_state("No incident rooms match these filters.")

        true ->
          empty_state(
            "No incident rooms yet. A room appears here once Ryker is asked to open one from a conversation."
          )
      end,
      "</div>"
    ]
  end

  defp incident_status(:requested), do: {"Requested", "active"}
  defp incident_status(:ready), do: {"Ready", "done"}
  defp incident_status(:blocked), do: {"Needs attention", "attention"}
  defp incident_status(:closed), do: {"Closed", "quiet"}

  defp incident_status(status) when is_binary(status) and status in @incident_statuses,
    do: incident_status(String.to_existing_atom(status))

  defp incident_status(status), do: {Components.label(status), "quiet"}

  defp lifecycle_status(status) do
    {label, tone} = Components.lifecycle(status)
    Components.status(label, tone)
  end

  defp publication_status(nil), do: "None"

  defp publication_status(status) do
    tone =
      case to_string(status) do
        "blocked" -> "attention"
        "published" -> "done"
        "discarded" -> "quiet"
        _pending -> "active"
      end

    Components.status(Components.label(to_string(status)), tone)
  end

  def incident(%{room: room, lifecycle: lifecycle, records: records, publication: publication}) do
    lifecycle_rows =
      Enum.map(lifecycle, fn event ->
        [
          readable_time(event.occurred_at),
          escape(Components.label(event.kind)),
          escape(event.channel_ref)
        ]
      end)

    record_rows =
      Enum.map(records, fn record ->
        [
          ["<code>", escape(record.ref), "</code>"],
          escape(record.kind),
          escape(record.status),
          escape(record.subject || "—")
        ]
      end)

    {status, tone} = incident_status(room.status)

    [
      definition_list([
        {"Reference", room.ref},
        {"Status", {:safe, Components.status(status, tone)}},
        {"Repository", room.repository_ref},
        {"Workspace", room.workspace_ref},
        {"Source channel", room.source_channel_ref},
        {"Incident channel", room.channel_ref || "Not created yet"},
        {"Channel state", Components.label(room.channel_state)},
        {"Visibility", if(room.private, do: "Private", else: "Public")},
        {"Source episode", {:safe, episode_link(room.source_episode_ref)}},
        {"Investigation episode", {:safe, episode_link(room.episode_ref)}},
        {"Requested", room.requested_at},
        {"Updated", room.updated_at}
      ]),
      "<section><h2>Room lifecycle</h2>",
      if(lifecycle_rows == [],
        do: empty_state("No lifecycle events recorded yet."),
        else: data_table(["At", "Observation", "Channel"], lifecycle_rows)
      ),
      "</section><section><h2>Evidence-backed records</h2>",
      if(record_rows == [],
        do: empty_state("No evidence-backed records are linked to this room."),
        else: data_table(["Record", "Kind", "Status", "Subject"], record_rows)
      ),
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
          lifecycle_status(item.status),
          schedule_next(item),
          escape(item.repository || "None"),
          integer(item.failures)
        ]
      end)

    [
      "<div class=\"schedules-page\">",
      configuration_guide(:schedules),
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
    rows = Enum.map(occurrences, &occurrence_row/1)

    [
      "<div class=\"action-controls\">",
      schedule_controls(schedule),
      "<a href=\"/conversations\">Replace in a conversation…</a></div>",
      definition_list(schedule_facts(schedule)),
      "<section><h2>What it asks for</h2><pre class=\"record-body\">",
      escape(schedule.task),
      "</pre></section><section><h2>Execution history</h2>",
      if(rows == [],
        do: empty_state("No occurrence has been dispatched or missed yet."),
        else:
          data_table(
            [
              "Due",
              "Trigger",
              "Dispatch",
              "Episode",
              "Execution",
              "Timing",
              {"row-number", "Attempts"},
              "Failure",
              "Reason"
            ],
            rows
          )
      ),
      "</section>"
    ]
  end

  defp schedule_facts(schedule) do
    [
      {"Reference", schedule.ref},
      {"Status", {:safe, lifecycle_status(schedule.status)}},
      {"Revision", schedule.revision},
      {"Recurrence", schedule.recurrence},
      {"Timezone", schedule.timezone},
      {"Authority", Components.label(schedule.authority)},
      {"Repository", schedule.repository || "None"},
      {"Destination", destination(schedule)},
      {"Next occurrence", schedule.next_occurrence_at || "None scheduled"},
      {"Expires", schedule.expires_at || "Never"},
      {"Failures", schedule.failure_count},
      {"Last failure", schedule.last_error || "None"},
      {"Source episode", {:safe, episode_link(schedule.source_episode_ref)}}
    ]
  end

  # One dispatched or missed occurrence: when it was due, how it was triggered
  # and dispatched, the episode it became and how that execution went.
  defp occurrence_row(occurrence) do
    finished =
      Map.get(occurrence, :delivered_at) || Map.get(occurrence, :finished_at) ||
        Map.get(occurrence, :accepted_at)

    [
      readable_time(occurrence.scheduled_for),
      escape(Components.label(Map.get(occurrence, :trigger, :scheduled))),
      escape(Components.label(occurrence.status)),
      episode_link(occurrence.episode_ref),
      [
        escape(Map.get(occurrence, :episode_state) || "—"),
        " / ",
        escape(Map.get(occurrence, :turn_status) || "—")
      ],
      [time_or_dash(Map.get(occurrence, :started_at)), " → ", time_or_dash(finished)],
      integer(Map.get(occurrence, :work_attempt_count, 0) || 0),
      escape(occurrence_failure(occurrence)),
      escape(occurrence.missed_reason || "—")
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
      configuration_guide(:subscriptions),
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

  # One comparison table of every channel Ryker knows about. The name
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
          Components.status(membership, tone),
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
      configuration_guide(:memory),
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
      lifecycle_status(item.status),
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
    [failure_summary([]), empty_state("Nothing needs attention.")]
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
          Components.status(status, tone),
          [
            "<span title=\"",
            escape(row.summary),
            "\">",
            escape(workspace_reason(row)),
            "</span>"
          ],
          workspace_request_state(row),
          readable_time(row.updated_at),
          action
        ]
      end)

    [
      "<div class=\"workspaces-page\">",
      page_help("workspaces-help", "How working copies are kept and cleaned up", [
        "<p>These are the repository checkouts tasks work in, not Slack workspaces. Ryker keeps unfinished or unmerged work safe: a copy with uncommitted or unpublished changes is preserved until cleanup is safe, and discarding unmerged commits always requires confirmation.</p>",
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

  # A learning working copy belongs to no request; its column says what owns it.
  defp workspace_request_state(%{execution_kind: :learning}), do: "Background learning"
  defp workspace_request_state(row), do: escape(Components.label(to_string(row.state)))

  defp workspace_request_label(row) do
    title = row[:request_title] || "Open request →"

    case SlackNames.workspace_from_destination(row[:request_conversation]) do
      nil -> escape(title)
      workspace -> SlackMarkdown.mentions(title, workspace)
    end
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
      "<li><strong>Connect the worker.</strong> Configure the authenticated worker gateway, then issue a one-time enrollment token with <code>mix ryker.coop_worker enroll WORKER_ID WORKSPACE_REF OPERATOR_REF</code> using the release’s database environment. Keep the token private. Configure the worker’s gateway URL, CA, repository, actual policy digests and capabilities, then run <code>coop worker connect --config /etc/coop/worker.json</code>. Its local co:op session service must already be running under the same OS user. These names and paths are examples, not ready-to-run values.</li>",
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
    <pre><code>MIX_ENV=prod mix ryker.doctor</code></pre>
    <p>It reports the applied revision beside the saved one, so a save that could not be assembled is visible rather than assumed. Finally, verify worker eligibility, workspace save/restore and required build tools before retrying. Do not rotate the gateway’s checkpoint encryption key: existing saved work depends on it.</p>
    </details>
    """
  end

  def usage(snapshot),
    do: UsagePage.render(snapshot)

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
      "</div>"
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

  @doc false
  # The inline editor of one operator message: a hidden form bound to that
  # message's exact edit route and token, holding the stored body, with Cancel
  # and Save at its lower edge. The page's script shows it in place of the
  # rendered body; nothing here is a disclosure, a heading or a second copy.
  def lab_message_editor(%{
        message_controls: %{edit: %{path: edit_path, token: edit_token}},
        item_id: item_id,
        text: text
      })
      when is_binary(item_id) do
    editor_id = "lab-edit-#{item_id}"

    [
      "<form class=\"lab-edit-form\" id=\"",
      editor_id,
      "\" method=\"post\" action=\"",
      escape(edit_path),
      "\" data-lab-edit=\"",
      escape(item_id),
      "\" hidden><input type=\"hidden\" name=\"_token\" value=\"",
      escape(edit_token),
      "\"><label class=\"sr-only\" for=\"",
      editor_id,
      "-text\">Edit message</label><textarea id=\"",
      editor_id,
      "-text\" name=\"message\" maxlength=\"20000\" data-max-bytes=\"20000\" rows=\"1\">",
      escape(text),
      "</textarea><p class=\"lab-edit-error\" id=\"",
      editor_id,
      "-error\" role=\"alert\" hidden></p><div class=\"lab-edit-actions\">",
      "<span class=\"lab-edit-hint\">Enter adds a line · ⌘ / Ctrl + Enter saves · Esc cancels</span>",
      "<button type=\"button\" class=\"lab-edit-cancel\">Cancel</button>",
      "<button type=\"submit\" class=\"lab-edit-save\">Save</button></div></form>"
    ]
  end

  def lab_message_editor(_message), do: ""

  @doc false
  # The reactions row under a delivered reply, as in Slack: the recorded pills,
  # then the add-reaction button at the end of the row with its anchored picker.
  def lab_message_reactions(%{reaction_controls: %{path: path, token: token}} = message)
      when is_binary(path) and is_binary(token) do
    [
      "<div class=\"lab-reactions\">",
      lab_reaction_pills(message),
      lab_reaction_picker(message),
      "</div>"
    ]
  end

  def lab_message_reactions(_message), do: ""

  @doc false
  # The compact action row under an operator message: Edit, which opens the
  # editor above, and its own exact Delete form.
  def lab_message_actions(%{
        message_controls: %{delete: %{path: delete_path, token: delete_token}},
        item_id: item_id
      })
      when is_binary(item_id) do
    [
      "<div class=\"lab-message-actions\"><button type=\"button\" class=\"lab-edit-toggle\" aria-controls=\"lab-edit-",
      escape(item_id),
      "\" aria-expanded=\"false\">Edit</button><form class=\"lab-action-form\" method=\"post\" action=\"",
      escape(delete_path),
      "\"><input type=\"hidden\" name=\"_token\" value=\"",
      escape(delete_token),
      "\"><button class=\"lab-message-delete\" type=\"submit\">Delete</button></form></div>"
    ]
  end

  def lab_message_actions(_message), do: ""

  @quick_reactions [{"+1", "👍"}, {"heart", "❤️"}, {"eyes", "👀"}, {"tada", "🎉"}, {"rocket", "🚀"}]

  # Recorded reactions on a reply as small pills: one per emoji with the count
  # the reaction contract provides (its current reactors), pressed when the
  # local operator is among them. Each pill posts the real add or remove for
  # that emoji to that exact reply. A reply with none renders nothing here.
  defp lab_reaction_pills(%{
         feedback_reactions: reactions,
         reaction_controls: %{path: path, token: token}
       })
       when is_list(reactions) and reactions != [] and is_binary(path) and is_binary(token) do
    operator = ConversationLab.operator_actor_ref()

    pills =
      reactions
      |> Enum.group_by(& &1.emoji_name)
      |> Enum.sort_by(fn {emoji_name, _reactors} -> emoji_name end)
      |> Enum.map(fn {emoji_name, reactors} ->
        mine = Enum.any?(reactors, &(&1.actor_ref == operator))
        count = length(reactors)
        glyph = lab_emoji_glyph(emoji_name)

        [
          "<form class=\"lab-reaction-form lab-reaction-pill\" method=\"post\" action=\"",
          escape(path),
          "\"><input type=\"hidden\" name=\"_token\" value=\"",
          escape(token),
          "\"><input type=\"hidden\" name=\"action\" value=\"",
          if(mine, do: "remove", else: "add"),
          "\"><input type=\"hidden\" name=\"emoji\" value=\"",
          escape(emoji_name),
          "\"><button type=\"submit\" class=\"lab-reaction-pill-button\" aria-pressed=\"",
          if(mine, do: "true", else: "false"),
          "\" aria-label=\"",
          escape(
            ":#{emoji_name}: #{count} #{if count == 1, do: "reaction", else: "reactions"}, " <>
              if(mine, do: "remove yours", else: "add yours")
          ),
          "\"><span class=\"lab-reaction-glyph\" aria-hidden=\"true\">",
          escape(glyph),
          "</span><span class=\"lab-reaction-count\" aria-hidden=\"true\">",
          integer(count),
          "</span></button></form>"
        ]
      end)

    ["<div class=\"lab-reaction-pills\">", pills, "</div>"]
  end

  defp lab_reaction_pills(_message), do: ""

  # The add-reaction control, an icon with an accessible name and a tooltip,
  # and its anchored picker: the five quick choices and a custom-name form
  # whose label, field and Add button share one row and whose error slot is
  # tied to the field. The picker is ignored by live patches so an open picker
  # and a half-typed name survive a refresh.
  defp lab_reaction_picker(%{reaction_controls: %{path: path, token: token}, ref: ref})
       when is_binary(path) and is_binary(token) and is_binary(ref) do
    picker_id = "lab-reaction-picker-" <> lab_short_digest(ref)

    quick =
      Enum.map(@quick_reactions, fn {emoji_name, glyph} ->
        [
          "<form class=\"lab-reaction-form lab-reaction-quick\" method=\"post\" action=\"",
          escape(path),
          "\"><input type=\"hidden\" name=\"_token\" value=\"",
          escape(token),
          "\"><input type=\"hidden\" name=\"action\" value=\"add\"><input type=\"hidden\" name=\"emoji\" value=\"",
          escape(emoji_name),
          "\"><button type=\"submit\" aria-label=\"",
          escape("React with :#{emoji_name}:"),
          "\">",
          escape(glyph),
          "</button></form>"
        ]
      end)

    [
      "<button type=\"button\" class=\"lab-reaction-toggle\" aria-label=\"Add reaction\" title=\"Add reaction\" aria-haspopup=\"true\" aria-expanded=\"false\" aria-controls=\"",
      picker_id,
      "\"><svg class=\"ui-icon\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.6\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\"><path d=\"M21 12a9 9 0 1 1-9-9 M8.5 14a4.5 4.5 0 0 0 7 0 M9 9.5h.01 M15 9.5h.01 M19 2v6 M16 5h6\"/></svg></button>",
      "<div class=\"lab-reaction-picker\" id=\"",
      picker_id,
      "\" role=\"group\" aria-label=\"Add a reaction\" phx-update=\"ignore\" hidden><div class=\"lab-reaction-quick-row\">",
      quick,
      "</div><form class=\"lab-reaction-form lab-reaction-custom\" method=\"post\" action=\"",
      escape(path),
      "\"><input type=\"hidden\" name=\"_token\" value=\"",
      escape(token),
      "\"><input type=\"hidden\" name=\"action\" value=\"add\"><label for=\"",
      picker_id,
      "-name\">Emoji name</label><div class=\"lab-reaction-custom-row\"><input id=\"",
      picker_id,
      "-name\" name=\"emoji\" type=\"text\" maxlength=\"100\" autocomplete=\"off\" spellcheck=\"false\" placeholder=\"white_check_mark\" aria-describedby=\"",
      picker_id,
      "-error\"><button type=\"submit\" class=\"lab-reaction-add\">Add</button></div><p class=\"lab-reaction-error\" id=\"",
      picker_id,
      "-error\" role=\"alert\" hidden></p></form></div>"
    ]
  end

  defp lab_reaction_picker(_message), do: ""

  defp lab_emoji_glyph(emoji_name) do
    case List.keyfind(@quick_reactions, emoji_name, 0) do
      {_name, glyph} -> glyph
      nil -> ":#{emoji_name}:"
    end
  end

  defp lab_short_digest(value) do
    :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  defp lab_reaction(reaction) do
    [
      "<span class=\"reaction-chip\" data-reaction-status=\"",
      escape(reaction.status),
      "\" title=\"Ryker reaction · ",
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

  defp failure_episode(%{execution_kind: :learning}), do: "Background learning"

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

  defp configuration_guide(page) do
    %{__changed__: nil, page: page}
    |> ConfigurationGuide.render()
    |> Safe.to_iodata()
  end

  defp result_count(count, one, many) do
    %{__changed__: nil, count: count, one: one, many: many}
    |> Components.result_count()
    |> Safe.to_iodata()
  end

  defp empty_state(text), do: ["<p class=\"empty-state\">", escape(text), "</p>"]

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

  defp publication_detail(nil), do: empty_state("Nothing was published from this incident.")

  defp publication_detail(publication) do
    definition_list([
      {"Reference", publication.ref},
      {"Status", {:safe, publication_status(publication.status)}},
      {"Repository", publication.repository},
      {"Branch", publication.branch_ref || "Not created"},
      {"Commit", publication.commit_sha || "Not created"},
      {"Pull request", publication.pr_number || "Not opened"},
      {"Pull request URL", publication.pr_url || "Not opened"},
      {"Last failure", publication.last_error || "None"},
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
      [] -> "None"
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

  defp freshness_detail(nil),
    do: empty_state("No frozen freshness-v2 receipt is retained for this repository.")

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

  defp value({:safe, value}), do: value
  defp value(%DateTime{} = value), do: readable_time(value)
  defp value(value), do: escape(value)

  defp time_or_dash(nil), do: "—"
  defp time_or_dash(value), do: readable_time(value)

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
