defmodule Ryker.ControlPlane.LearningPage do
  @moduledoc """
  Learning (`/memory/learning`): whether background learning runs here and
  what it has not read yet, the batches that need a person, what it did
  recently, the handovers it could not save and the worker sessions it holds.

  One batch opens in place with its attempts, the way to grant it one more
  model start, and, for a chosen attempt, exactly how it was learned. The
  switch that turns learning on or off is the page's one action, rendered by
  the shell opposite the title.
  """
  use Phoenix.Component

  import Ryker.ControlPlane.Components, only: [action_button: 1, pager: 1]

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{CSRF, Kit, LearningActivity, LearningReceipt, MemoryFormat}

  @doc "The query keys the Learning page reads."
  def query_keys, do: LearningActivity.query_keys()

  @doc """
  The Learning body for a `LearningActivity` projection and the worker
  sessions the Working copies projection lists; only learning sessions that
  are still open are shown.
  """
  @spec html(map(), [map()], String.t() | nil) :: iodata()
  def html(activity, sessions, csrf_secret) do
    %{
      __changed__: nil,
      activity: activity,
      sessions: Enum.filter(sessions, &open_learning_session?/1),
      csrf_secret: csrf_secret
    }
    |> render()
    |> Safe.to_iodata()
  end

  def render(assigns) do
    ~H"""
    <div class="memory-view memory-learning">
      <%= if @activity.selected do %>
        <.batch batch={@activity.selected} receipt={@activity.receipt} csrf_secret={@csrf_secret} />
      <% else %>
        <.status activity={@activity} />
        <section :if={@activity.attention.total > 0} id="needs-attention" class="memory-section">
          <Kit.section_head
            title="Needs attention"
            lede="Learning stopped for these conversations. Review one to see what happened and whether to try again."
          />
          <Kit.entity_list label="Learning that needs attention">
            <Kit.entity_row
              :for={batch <- @activity.attention.items}
              id={"batch-" <> batch.id}
              icon={:book}
              name={batch.conversation}
              href={batch.path}
              text={batch.error}
              meta={[
                batch.repository,
                MemoryFormat.count(batch.input_count, "message", "messages"),
                starts(batch),
                MemoryFormat.time(batch.at),
                MemoryFormat.time(batch.next_attempt_at, "Next check ")
              ]}
            >
              <:actions><a class="ui-button secondary" href={batch.path}>Review</a></:actions>
            </Kit.entity_row>
          </Kit.entity_list>
          <.pager
            page={@activity.attention.page}
            pages={@activity.attention.pages}
            path={&path("attention_page", &1)}
            label="Pages of learning that needs attention"
          />
        </section>
        <section id="recent" class="memory-section">
          <Kit.section_head
            title="Recent"
            lede="Each pass reads new messages from one conversation and updates what Ryker knows. Finding nothing to change is a normal outcome."
          />
          <Kit.toolbar :if={finished_or_running(@activity) > 0}>
            <Kit.segmented label="Show by outcome" options={outcomes(@activity.recent.outcome)} />
          </Kit.toolbar>
          <Kit.entity_list :if={@activity.recent.items != []} label="Recent learning">
            <Kit.entity_row
              :for={batch <- @activity.recent.items}
              id={"batch-" <> batch.id}
              icon={:book}
              name={batch.conversation}
              href={batch.path}
              state={state(batch.status)}
              text={batch.error}
              meta={[
                batch.repository,
                MemoryFormat.count(batch.input_count, "message", "messages"),
                MemoryFormat.time(batch.at)
              ]}
            />
          </Kit.entity_list>
          <Kit.empty
            :if={@activity.recent.items == [] and @activity.recent.outcome != ""}
            title="Nothing with this outcome yet"
            text="Choose All to see every recent pass."
          />
          <Kit.empty
            :if={@activity.recent.items == [] and @activity.recent.outcome == ""}
            title="Nothing learned yet"
            text={
              if @activity.state == :off,
                do: "Learning is off, so Ryker is not reading new messages. Turn it on to start.",
                else:
                  "Ryker groups new messages by conversation and reads them in the background. Each pass appears here."
            }
          />
          <.pager
            page={@activity.recent.page}
            pages={@activity.recent.pages}
            path={&path("page", &1, @activity.recent.outcome)}
            label="Pages of recent learning"
            earlier="← Newer"
            later="Older →"
          />
        </section>
        <section
          :if={@activity.handover_failures.total > 0}
          id="context-not-saved"
          class="memory-section"
        >
          <Kit.section_head
            title="Context not saved"
            lede="After these replies, Ryker could not save a summary for the next request in the conversation. The replies themselves were not affected."
          />
          <Kit.entity_list label="Context not saved">
            <Kit.entity_row
              :for={failure <- @activity.handover_failures.items}
              id={"handover-" <> failure.turn_id}
              name={failure.conversation}
              text={failure.explanation}
              meta={[
                failure.response_status,
                MemoryFormat.time(failure.at),
                MemoryFormat.link("Open request", failure.request_path)
              ]}
            />
          </Kit.entity_list>
          <.pager
            page={@activity.handover_failures.page}
            pages={@activity.handover_failures.pages}
            path={&path("handover_page", &1)}
            label="Pages of context not saved"
            earlier="← Newer"
            later="Older →"
          />
        </section>
        <section :if={@sessions != []} id="worker-sessions" class="memory-section">
          <Kit.section_head
            title="Worker sessions"
            lede="Each pass runs in a short session on a worker. Finished sessions close on their own."
          />
          <Kit.entity_list label="Learning worker sessions">
            <Kit.entity_row
              :for={session <- @sessions}
              id={"session-" <> dom_id(session.ref)}
              name="Learning session"
              state={session_state(session)}
              text={session_detail(session)}
              meta={[MemoryFormat.time(session.updated_at, "Updated ")]}
            >
              <:details>
                <details class="memory-details">
                  <summary>Details</summary>
                  <p>Session <code>{session.ref}</code></p>
                </details>
              </:details>
              <:actions :if={session[:action] == :rearm}>
                <.action_button
                  path={"/actions/retention/#{segment(session.ref)}/rearm"}
                  label="Resume cleanup"
                />
              </:actions>
            </Kit.entity_row>
          </Kit.entity_list>
        </section>
      <% end %>
    </div>
    """
  end

  attr(:activity, :map, required: true)

  defp status(assigns) do
    assigns = assign(assigns, :state, state_word(assigns.activity.state))

    ~H"""
    <Kit.status_line state={@state}>
      <span>{waiting(@activity.waiting_inputs)}</span>
      <span :if={@activity.waiting_inputs > 0 and @activity.oldest_waiting_at}>
        oldest waiting {MemoryFormat.waited(@activity.oldest_waiting_at)}
      </span>
      <a :if={@activity.counts.deferred > 0} data-tone="warn" href="#needs-attention">
        {MemoryFormat.count(@activity.counts.deferred, "needs attention", "need attention")}
      </a>
    </Kit.status_line>
    <p :if={state_note(@activity.state)} class="memory-note memory-status-note">
      {state_note(@activity.state)}
      <a :if={@activity.state == :cannot_start} href="/settings/advanced">Open Advanced settings</a>
    </p>
    """
  end

  attr(:batch, :map, required: true)
  attr(:receipt, :map, default: nil)
  attr(:csrf_secret, :string, default: nil)

  defp batch(assigns) do
    ~H"""
    <p class="memory-back"><a href="/memory/learning">← All learning</a></p>
    <article class="memory-record" id={"batch-" <> @batch.id}>
      <h2 class="memory-record-title">
        <span>{@batch.conversation}</span>
        <Kit.state tone={elem(state(@batch.status), 0)} word={elem(state(@batch.status), 1)} />
      </h2>
      <p :if={@batch.error} class="memory-record-lede">{@batch.error}</p>
      <p :if={@batch.status == :no_change} class="memory-record-lede">
        This pass found nothing to add or change. That is a normal outcome, not missing memory.
      </p>
      <MemoryFormat.facts facts={[
        MemoryFormat.link("Open conversation", @batch.conversation_path),
        @batch.repository,
        MemoryFormat.count(@batch.input_count, "message", "messages"),
        starts(@batch),
        if(@batch.mode == :shadow, do: "From shadow mode"),
        MemoryFormat.time(@batch.at, "Queued "),
        MemoryFormat.time(@batch.completed_at, "Finished "),
        MemoryFormat.time(@batch.next_attempt_at, "Next check ")
      ]} />
      <p :if={@batch.retry_blocked} class="memory-note">{@batch.retry_blocked}</p>
    </article>
    <section :if={@batch.retry_available && @csrf_secret} id="retry" class="memory-section">
      <Kit.section_head
        title="Try once more"
        lede={"Ryker reads these same messages again with one more model start, using the current learning policy, #{@batch.retry_policy}. The source messages are checked again first. Earlier attempts and the starts they used stay recorded."}
      />
      <form class="memory-retry" method="post" action={"/actions/learning/" <> @batch.id <> "/retry"}>
        <input type="hidden" name="budget_version" value={@batch.budget_version} />
        <input
          type="hidden"
          name="_token"
          value={
            CSRF.token(
              @csrf_secret,
              "learning:retry",
              LearningActivity.retry_resource(@batch.id, @batch.budget_version)
            )
          }
        />
        <button type="submit" class="ui-button primary">Grant one more start</button>
      </form>
    </section>
    <section id="attempts" class="memory-section">
      <Kit.section_head
        title="Attempts"
        lede="Each attempt keeps the exact request Ryker sent and the answer it got back."
      />
      <Kit.entity_list :if={@batch.attempts != []} label="Attempts">
        <Kit.entity_row
          :for={attempt <- @batch.attempts}
          id={"attempt-" <> attempt.id}
          name={"Attempt #{attempt.number}"}
          href={LearningActivity.attempt_path(@batch.id, attempt.id)}
          state={attempt_state(attempt)}
          text={attempt.error}
          meta={[
            MemoryFormat.time(attempt.at),
            if(attempt.pruned_at, do: "Saved text expired")
          ]}
        />
      </Kit.entity_list>
      <Kit.empty
        :if={@batch.attempts == []}
        title="No attempts yet"
        text="Ryker has not prepared a model request for this batch."
      />
      <.pager
        page={@batch.attempt_page}
        pages={@batch.attempt_pages}
        path={&attempts_path(@batch, &1)}
        label="Attempt pages"
        earlier="← Newer attempts"
        later="Older attempts →"
      />
    </section>
    <details :if={@batch.error_code} class="memory-details">
      <summary>Details</summary>
      <p>Diagnostic code <code>{@batch.error_code}</code></p>
    </details>
    <LearningReceipt.render :if={@receipt} receipt={@receipt} />
    """
  end

  defp state_word(:on), do: {:on, "Learning is on"}
  defp state_word(:paused), do: {:warn, "Learning is paused"}
  defp state_word(:not_running), do: {:warn, "Learning is not running here"}
  defp state_word(:cannot_start), do: {:warn, "Learning can’t start"}
  defp state_word(:off), do: {:off, "Learning is off"}

  defp state_note(:off),
    do:
      "Ryker keeps new messages but learns nothing from them until learning is on. What it already learned stays available."

  defp state_note(:cannot_start),
    do: "Learning is turned on, but Ryker has no worker or model to learn with yet."

  defp state_note(:not_running),
    do:
      "Learning is set up, but its worker is not running in this Ryker process. New messages wait until it runs."

  defp state_note(:paused),
    do:
      "The worker gives learning sessions the project environment, MCP servers, write access or Ryker tools, so Ryker sends them nothing. Set project_env: false and project_mcp: false on the learning policy. Learning resumes by itself when the policy changes; new messages wait."

  defp state_note(_state), do: nil

  defp waiting(0), do: "No messages waiting"
  defp waiting(count), do: MemoryFormat.count(count, "message", "messages") <> " waiting"

  defp starts(batch),
    do:
      "#{batch.start_count} of #{MemoryFormat.count(batch.start_limit, "model start", "model starts")} used"

  defp state(:queued), do: {:off, LearningActivity.label(:queued)}
  defp state(:running), do: {:busy, LearningActivity.label(:running)}
  defp state(:applied), do: {:on, LearningActivity.label(:applied)}
  defp state(:no_change), do: {:off, LearningActivity.label(:no_change)}
  defp state(:deferred), do: {:warn, LearningActivity.label(:deferred)}
  defp state(:superseded), do: {:off, LearningActivity.label(:superseded)}

  defp attempt_state(%{status: status, label: label}) when status in [:rejected, :stale],
    do: {:warn, label}

  defp attempt_state(%{status: :prepared, label: label}), do: {:busy, label}
  defp attempt_state(%{label: "Knowledge updated" = label}), do: {:on, label}
  defp attempt_state(%{label: label}), do: {:off, label}

  # Only a list with something in it is worth filtering.
  defp finished_or_running(activity),
    do: activity.counts |> Map.drop([:deferred]) |> Map.values() |> Enum.sum()

  defp outcomes(current) do
    [{"All", ""} | Enum.map(LearningActivity.outcomes(), &{outcome_label(&1), &1})]
    |> Enum.map(fn {label, outcome} ->
      {label, path("page", 1, outcome), outcome == current}
    end)
  end

  defp outcome_label("updated"), do: "Updated"
  defp outcome_label("no_change"), do: "No change"
  defp outcome_label("in_progress"), do: "In progress"
  defp outcome_label("sources_changed"), do: "Sources changed"

  defp path(key, page, outcome \\ "") do
    query =
      [{"outcome", outcome}, {key, page}]
      |> Enum.reject(fn {name, value} -> value in [nil, ""] or {name, value} == {"page", 1} end)

    case URI.encode_query(query) do
      "" -> "/memory/learning"
      encoded -> "/memory/learning?" <> encoded
    end
  end

  defp attempts_path(batch, page),
    do:
      "/memory/learning?" <>
        URI.encode_query(%{"batch" => batch.id, "attempt_page" => page}) <> "#attempts"

  # Worker sessions, worded the way the Working copies page used to word them
  # when learning sessions were listed there.
  defp open_learning_session?(session),
    do: Map.get(session, :execution_kind) == :learning and session[:status] != :discarded

  defp session_state(%{status: :grace}), do: {:off, "Cleanup scheduled"}

  defp session_state(%{status: :active, learning_state: :retry_scheduled}),
    do: {:warn, "Retry scheduled"}

  defp session_state(%{status: :active, learning_state: :checking_worker}),
    do: {:busy, "Checking worker"}

  defp session_state(%{status: :active, learning_state: :cleanup_pending}),
    do: {:off, "Cleanup pending"}

  defp session_state(%{status: :active}), do: {:busy, "In use"}
  defp session_state(%{status: :retained}), do: {:off, "Changes preserved"}
  defp session_state(%{status: :blocked}), do: {:warn, "Cleanup needs attention"}
  defp session_state(_session), do: {:busy, "Cleanup in progress"}

  defp session_detail(%{status: :grace, discard_after: %DateTime{} = at}),
    do: sentence(["Cleanup ", MemoryFormat.time(at), "."])

  # Only an attempt that may have reached the model waits here; one that never
  # sent the model anything closes without its worker's answer.
  defp session_detail(%{learning_state: :retry_scheduled, learning_retry_at: %DateTime{} = at}),
    do:
      sentence([
        "The worker has not confirmed that this session stopped. Ryker checks again ",
        MemoryFormat.time(at),
        "."
      ])

  defp session_detail(%{learning_state: :retry_scheduled}),
    do: "The worker has not confirmed that this session stopped. Ryker checks again on its own."

  defp session_detail(%{learning_state: :checking_worker}),
    do: "Ryker is confirming whether the worker session stopped."

  defp session_detail(%{learning_state: :cleanup_pending}),
    do: "Learning is done with this session. Cleanup is next."

  defp session_detail(%{status: :blocked, summary: "coop_error"}),
    do: "The worker could not finish this step. Inspect the saved error before retrying."

  defp session_detail(%{status: :blocked, summary: "coop_unavailable"}),
    do: "The worker could not be reached. Check its connection, then retry."

  defp session_detail(%{status: :blocked, summary: summary}) when is_binary(summary),
    do: summary |> String.replace("_", " ") |> String.capitalize()

  defp session_detail(_session), do: nil

  defp sentence(parts) do
    {:safe,
     Enum.map(parts, fn
       {:safe, html} -> html
       nil -> []
       text -> Plug.HTML.html_escape(text)
     end)}
  end

  defp dom_id(ref), do: String.replace(to_string(ref), ~r/[^A-Za-z0-9_-]/, "-")
  defp segment(value), do: value |> to_string() |> URI.encode(&URI.char_unreserved?/1)
end
