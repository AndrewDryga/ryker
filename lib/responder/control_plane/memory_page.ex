defmodule Responder.ControlPlane.MemoryPage do
  @moduledoc false
  use Phoenix.Component
  import Responder.ControlPlane.Components, only: [filter_toolbar: 1, result_count: 1]
  alias Responder.ControlPlane.{CSRF, LearningActivity, SlackMarkdown}

  @views [
    {"knowledge", "Current knowledge", "knowledge topic", "knowledge topics"},
    {"notes", "Source excerpts", "source excerpt", "source excerpts"},
    {"summaries", "Conversation handovers", "conversation handover", "conversation handovers"}
  ]

  # What Responder learned from conversations: the learning state line (it is
  # functional state, so it stays visible), the three views as compact tabs,
  # the one toolbar that searches within the chosen view, a quiet count, the
  # entries with their recall warnings, then the related history and learning
  # activity beneath. The shell renders the title, description and help.
  def render(assigns) do
    ~H"""
    <div class="conversation-memory" role="region" aria-label="Learned from conversations">
      <div :if={Map.get(@view, :learning_activity)} class="learning-summary">
        <strong>{learning_state(@view.learning_activity)}</strong>
        <span>{count_label(@view.learning_activity.waiting_inputs, "message")} waiting</span>
        <a :if={@view.learning_activity.handover_failures.total > 0} href="#handover-failures">
          Handovers not saved: {@view.learning_activity.handover_failures.total}
        </a>
        <a href="#learning-activity">Inspect learning activity →</a>
      </div>
      <nav class="memory-views" aria-label="Conversation memory views">
        <a
          :for={{kind, label, _one, _many} <- views()}
          href={path(@view, kind, 1)}
          aria-current={if @view.kind == kind, do: "page"}
        >
          {label} <span>{Map.fetch!(@view.counts, String.to_existing_atom(kind))}</span>
        </a>
      </nav>
      <.filter_toolbar
        id="memory-search"
        path="/memory"
        label="Search conversation memory"
        placeholder="Topics, decisions or context"
        query={@view.q}
        filtered={@view.q != ""}
        hidden={[{"kind", @view.kind}]}
        clear={"/memory?" <> URI.encode_query(%{"kind" => @view.kind})}
      />
      <.result_count
        :if={@view.total > 0}
        count={@view.total}
        one={noun(@view.kind, 2)}
        many={noun(@view.kind, 3)}
      />
      <p :if={@view.selected}><a href={path(@view, "knowledge", 1)}>← All knowledge</a></p>
      <p :if={@view.total == 0} class="empty-state">
        {if @view.q != "", do: "No matching conversation memory.", else: "Nothing learned here yet."}
      </p>
      <div class="memory-cards">
        <article :for={item <- @view.items} class="memory-card" id={"memory-#{item.id}"}>
          <header>
            <h2>{if item.title == "", do: item.conversation, else: item.title}</h2>
            <time datetime={DateTime.to_iso8601(item.at)}>{Calendar.strftime(
              item.at,
              "%d %b, %H:%M UTC"
            )}</time>
          </header>
          <p class="memory-source"><a href={item.conversation_path}>{item.conversation}</a>
            <span :if={item.repository}>{item.repository}</span></p>
          <p
            :if={Map.get(item, :recall_warning) in [:missing_source_history, :invalid_source_history]}
            class="memory-unavailable"
          >
            Not used for recall · {if item.recall_warning == :missing_source_history,
              do: "No complete source history was saved.",
              else: "Source history is invalid."} Kept for inspection.
          </p>
          <p :if={Map.get(item, :available) == false} class="memory-unavailable">
            Not used for recall · a supporting source changed, was removed, or expired.
            Its old history cannot be reused for learning. Saved revisions remain available for inspection.
          </p>
          <p :if={Map.get(item, :maintenance_error)} class="memory-unavailable">
            Handover maintenance: {item.maintenance_error}
            <span :if={item.maintenance_retry_at}>Next check: {date(item.maintenance_retry_at)}.</span>
          </p>
          <div class="markdown-preview">{Phoenix.HTML.raw(preview(item.text, item.workspace))}</div>
          <div :for={{label, values} <- item.groups} class="memory-facts">
            <h3>{label}</h3><ul>
              <li :for={value <- values}>{Phoenix.HTML.raw(preview(value, item.workspace))}</li>
            </ul>
          </div>
          <footer>
            <span :if={Map.has_key?(item, :source_count)}>Sources: {item.direct_source_count} direct · {item.inherited_source_count} inherited</span>
            <a
              :if={Map.has_key?(item, :version)}
              href={"/memory?" <> URI.encode_query(%{"kind" => "knowledge", "item" => item.id})}
            >
              {if Map.get(item, :available) == false,
                do: "History and relearning",
                else: "Update history"} · {item.version} {if item.version == 1,
                do: "revision",
                else: "revisions"} →
            </a>
            <a :if={item.source} href={item.source} rel="noopener noreferrer">Source message →</a>
            <a :if={item.request_path} href={item.request_path}>Source request →</a>
            <span class="memory-expiry">Retention: {retention_label(item)}</span>
          </footer>
          <dl class="memory-dates">
            <div>
              <dt>Learned or changed</dt><dd>
                <time datetime={iso(item.changed_at)}>{date(item.changed_at)}</time>
              </dd>
            </div>
            <div :if={item.source_at}>
              <dt>Latest source message</dt><dd>
                <time datetime={iso(item.source_at)}>{date(item.source_at)}</time>
              </dd>
            </div>
          </dl>
        </article>
      </div>
      <Responder.ControlPlane.RelearnPanel.render
        :if={Map.get(@view, :rebuild)}
        preview={@view.rebuild}
        csrf_secret={Map.get(assigns, :csrf_secret)}
      />
      <section :if={@view.history != []} class="knowledge-history" aria-label="Update history">
        <h2>Update history</h2>
        <p>
          Each update preserves what was known then. Source times are separate from when Responder learned it.
        </p>
        <ol>
          <li :for={revision <- @view.history}>
            <header>
              <strong>Update {revision.version}</strong>
              <time datetime={DateTime.to_iso8601(revision.at)}>{Calendar.strftime(
                revision.at,
                "%d %b, %H:%M UTC"
              )}</time>
            </header>
            <div class="markdown-preview">{Phoenix.HTML.raw(preview(revision.text, nil))}</div>
            <small>Source message · {Calendar.strftime(revision.source_at, "%d %b %Y, %H:%M UTC")}</small>
            <a :if={revision.source} href={revision.source} rel="noopener noreferrer">Open source →</a>
            <a :if={revision.learning_path} href={revision.learning_path}>How this was learned →</a>
          </li>
        </ol>
        <nav :if={@view.history_pages > 1} class="pagination" aria-label="Update history pages">
          <a :if={@view.history_page > 1} href={history_path(@view, @view.history_page - 1)}>← Newer updates</a>
          <span>Page {@view.history_page} of {@view.history_pages}</span>
          <a
            :if={@view.history_page < @view.history_pages}
            href={history_path(@view, @view.history_page + 1)}
          >Older updates →</a>
        </nav>
      </section>
      <.learning
        :if={Map.get(@view, :learning_activity)}
        activity={@view.learning_activity}
        csrf_secret={Map.get(assigns, :csrf_secret)}
      />
      <Responder.ControlPlane.LearningReceipt.render :if={@view.learning} receipt={@view.learning} />
      <nav :if={@view.pages > 1} class="pagination" aria-label="Memory pages">
        <a :if={@view.page > 1} href={path(@view, @view.kind, @view.page - 1)}>← Previous</a>
        <span>Page {@view.page} of {@view.pages}</span>
        <a :if={@view.page < @view.pages} href={path(@view, @view.kind, @view.page + 1)}>Next →</a>
      </nav>
    </div>
    """
  end

  defp learning(assigns) do
    ~H"""
    <section id="learning-activity" class="learning-activity" aria-label="Learning activity">
      <header class="learning-activity-heading">
        <h2>Learning activity</h2>
        <p>
          {cond do
            not @activity.enabled -> "Learning is disabled"
            @activity.worker_running -> "Learning is enabled"
            true -> "Configured · worker is not running here"
          end}
        </p>
      </header>
      <p :if={!@activity.enabled} class="memory-unavailable">
        Messages are retained, but no background model is maintaining knowledge.
        Configure the learning worker to process them; existing saved knowledge remains available.
      </p>
      <p class="learning-queue">
        {count_label(@activity.waiting_inputs, "message")} waiting
        <span :if={@activity.oldest_waiting_at}>
          · oldest waiting {age(@activity.oldest_waiting_at)}
          <time datetime={iso(@activity.oldest_waiting_at)}> (since {date(@activity.oldest_waiting_at)})</time>
        </span>
      </p>
      <p class="learning-explanation">
        Messages are grouped by conversation. A pass updates an existing subject, creates useful new knowledge, or makes no change. Learning never sends a reply.
      </p>
      <details
        :if={@activity.handover_failures.total > 0}
        id="handover-failures"
        class="handover-failures"
      >
        <summary>
          <strong>Conversation handovers not saved</strong> · {@activity.handover_failures.total}
        </summary>
        <p>
          A handover helps future work recall what happened. This does not change the response or its delivery status. Background learning from retained messages is a separate process.
        </p>
        <ul class="learning-attempts">
          <li :for={failure <- @activity.handover_failures.items}>
            <strong>Conversation handover not saved · {failure.conversation}</strong>
            <p>{failure.explanation}</p>
            <p>
              {failure.response_status} · <time datetime={iso(failure.at)}>{date(failure.at)}</time>
            </p>
            <a href={failure.request_path}>Inspect work turn →</a>
          </li>
        </ul>
        <nav
          :if={@activity.handover_failures.pages > 1}
          class="pagination"
          aria-label="Handover failure pages"
        >
          <a
            :if={@activity.handover_failures.page > 1}
            href={handovers_path(@activity.handover_failures.page - 1)}
          >← Newer handovers</a>
          <span>Page {@activity.handover_failures.page} of {@activity.handover_failures.pages}</span>
          <a
            :if={@activity.handover_failures.page < @activity.handover_failures.pages}
            href={handovers_path(@activity.handover_failures.page + 1)}
          >Older handovers →</a>
        </nav>
      </details>
      <nav class="learning-outcomes" aria-label="Learning outcomes">
        <a href="/memory#learning-activity" aria-current={if @activity.filter == "", do: "page"}>All batches</a>
        <a
          :for={state <- [:queued, :running, :deferred, :applied, :no_change, :superseded]}
          href={learning_path(@activity, 1, Atom.to_string(state))}
          aria-current={if @activity.filter == Atom.to_string(state), do: "page"}
        >
          {LearningActivity.label(state)} <strong>{@activity.counts[state]}</strong>
        </a>
      </nav>
      <p :if={@activity.total == 0} class="empty-state">No learning batches in this view.</p>
      <ol class="learning-batches">
        <li :for={batch <- @activity.items}>
          <div>
            <a href={batch.path}><strong>{batch.label}</strong> · {batch.conversation}</a>
            <p>
              {count_label(batch.input_count, "message")} · {count_label(
                batch.start_count,
                "model start"
              )} · {batch.mode}
            </p>
          </div>
          <time datetime={iso(batch.at)}>{date(batch.at)}</time>
        </li>
      </ol>
      <nav :if={@activity.pages > 1} class="pagination" aria-label="Learning batch pages">
        <a :if={@activity.page > 1} href={learning_path(@activity, @activity.page - 1)}>← Newer batches</a>
        <span>Page {@activity.page} of {@activity.pages}</span>
        <a :if={@activity.page < @activity.pages} href={learning_path(@activity, @activity.page + 1)}>Older batches →</a>
      </nav>
      <article :if={@activity.selected} class="learning-batch-detail">
        <h3>{@activity.selected.label} · {@activity.selected.conversation}</h3>
        <p>
          <a href={@activity.selected.conversation_path}>Open conversation →</a>
          <span :if={@activity.selected.repository}> · {@activity.selected.repository}</span>
        </p>
        <p>
          {count_label(@activity.selected.input_count, "message")} · {@activity.selected.start_count} of {count_label(
            @activity.selected.start_limit,
            "approved model start"
          )} used
        </p>
        <p
          :if={@activity.selected.error}
          class={
            if @activity.selected.status == :deferred,
              do: "memory-unavailable",
              else: "learning-explanation"
          }
        >
          {@activity.selected.error}
        </p>
        <p :if={@activity.selected.status == :no_change}>
          This pass did not add or change knowledge. That is a valid outcome, not a missing memory.
        </p>
        <p :if={@activity.selected.next_attempt_at}>
          Next scheduled check:
          <time datetime={iso(@activity.selected.next_attempt_at)}>{date(
            @activity.selected.next_attempt_at
          )}</time>
        </p>
        <p :if={@activity.selected.retry_blocked}>{@activity.selected.retry_blocked}</p>
        <details :if={@activity.selected.retry_available && @csrf_secret} class="learning-retry">
          <summary>Review retry</summary>
          <p>
            Grant exactly one additional model start for these same inputs. Previously spent starts stay recorded. Current source access and earlier executions are checked again before this is allowed.
          </p>
          <p>
            The current learning policy, <code>{@activity.selected.retry_policy}</code>, will be used.
            Earlier attempts keep their original policy and history.
          </p>
          <form method="post" action={"/actions/learning/" <> @activity.selected.id <> "/retry"}>
            <input type="hidden" name="budget_version" value={@activity.selected.budget_version} />
            <input
              type="hidden"
              name="_token"
              value={
                CSRF.token(
                  @csrf_secret,
                  "learning:retry",
                  LearningActivity.retry_resource(
                    @activity.selected.id,
                    @activity.selected.budget_version
                  )
                )
              }
            />
            <button type="submit" class="ui-button primary">Grant one more start</button>
          </form>
        </details>
        <h4>Saved attempts</h4>
        <p :if={@activity.selected.attempts == []}>No model request was prepared for this batch.</p>
        <ol class="learning-attempts">
          <li :for={attempt <- @activity.selected.attempts}>
            <a href={LearningActivity.attempt_path(@activity.selected.id, attempt.id)}>Attempt {attempt.number} · {attempt.label} →</a>
            <span :if={attempt.pruned_at}> · saved text expired</span>
            <p :if={attempt.error}>{attempt.error}</p>
          </li>
        </ol>
        <nav
          :if={@activity.selected.attempt_pages > 1}
          class="pagination"
          aria-label="Learning attempt pages"
        >
          <a :if={@activity.selected.attempt_page > 1} href={attempts_path(@activity.selected, -1)}>← Newer attempts</a>
          <span>Page {@activity.selected.attempt_page} of {@activity.selected.attempt_pages}</span>
          <a
            :if={@activity.selected.attempt_page < @activity.selected.attempt_pages}
            href={attempts_path(@activity.selected, 1)}
          >Older attempts →</a>
        </nav>
        <details :if={@activity.selected.error_code}>
          <summary>Diagnostic code</summary><code>{@activity.selected.error_code}</code>
        </details>
      </article>
    </section>
    """
  end

  defp learning_path(activity, page, filter \\ nil),
    do:
      "/memory?" <>
        URI.encode_query(%{
          "learning_page" => page,
          "learning_status" => filter || activity.filter
        }) <> "#learning-activity"

  defp attempts_path(batch, offset),
    do:
      "/memory?" <>
        URI.encode_query(%{"batch" => batch.id, "attempt_page" => batch.attempt_page + offset}) <>
        "#learning-activity"

  defp handovers_path(page),
    do: "/memory?" <> URI.encode_query(%{"handover_page" => page}) <> "#handover-failures"

  defp views, do: @views

  defp noun(kind, index), do: @views |> List.keyfind!(kind, 0) |> elem(index)

  defp count_label(1, label), do: "1 " <> label
  defp count_label(count, label), do: "#{count} #{label}s"

  defp date(nil), do: "Not recorded"
  defp date(value), do: Calendar.strftime(value, "%d %b %Y, %H:%M UTC")
  defp iso(nil), do: nil
  defp iso(value), do: DateTime.to_iso8601(value)

  defp age(value) do
    seconds = max(0, DateTime.diff(DateTime.utc_now(), value))

    cond do
      seconds < 60 -> "less than a minute"
      seconds < 3600 -> "#{div(seconds, 60)} min"
      seconds < 86_400 -> "#{div(seconds, 3600)} hr"
      true -> "#{div(seconds, 86_400)} days"
    end
  end

  defp learning_state(%{enabled: false}), do: "Learning is disabled"
  defp learning_state(%{worker_running: true}), do: "Learning is enabled"
  defp learning_state(_), do: "Learning configured · worker is not running here"

  defp path(view, kind, page),
    do: "/memory?" <> URI.encode_query(%{"kind" => kind, "q" => view.q, "page" => page})

  defp history_path(view, page),
    do:
      "/memory?" <>
        URI.encode_query(%{
          "kind" => "knowledge",
          "item" => view.selected,
          "history_page" => page
        })

  defp retention_label(%{recall_warning: :missing_source_history}),
    do: "kept for inspection; no automatic expiry"

  defp retention_label(%{recall_warning: :invalid_source_history}),
    do: "unknown: source history is invalid"

  defp retention_label(%{expires_at: %DateTime{} = expires_at}),
    do: "until " <> date(expires_at)

  defp retention_label(_item), do: "automatic expiry is not configured"

  defp preview(text, workspace) do
    # Attribution commonly arrives as a bare Slack user ID in model summaries.
    text =
      if workspace,
        do: resolve_bare_people(text),
        else: text

    SlackMarkdown.preview(text, workspace)
  end

  defp resolve_bare_people(text) do
    # Code and existing Slack/Markdown links must retain their exact source bytes.
    protected =
      ~r/(```[\s\S]*?```|`[^`\n]+`|<[^>\n]+>|\[[^\]\n]+\]\([^\s)]+\)|https?:\/\/[^\s<>]+)/u

    protected
    |> Regex.split(text, include_captures: true)
    |> Enum.map_join(fn part ->
      if Regex.match?(protected, part),
        do: part,
        else: Regex.replace(~r/\b[UW][A-Z0-9]{8,}\b/, part, &mention/1)
    end)
  end

  defp mention(id), do: "<@#{id}>"
end
