defmodule Ryker.ControlPlane.LearningPage do
  @moduledoc """
  Learning (`/memory/learning`): whether background learning runs here and
  what it has not read yet, the batches that need a person, what it did
  recently, the handovers it could not save and the worker sessions it holds.

  One batch is a sub-page of its own (`heading/1` gives the shell its title
  and the way back to all learning): its state, what happened, what a person
  can do about a stopped batch, its attempts and their technical details.
  Each attempt opens on its learning card on the Timeline, which shows
  exactly how it was learned. The switch that turns learning on or off is
  the list's one action, rendered by the shell opposite the title; a batch's
  page has none. An open page redraws when learning, the messages waiting
  for it or its sessions change (`subscriptions/0`).
  """
  use Phoenix.Component
  import Ryker.ControlPlane.Components, only: [action_button: 1, pager: 1]
  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.Components
  alias Ryker.ControlPlane.{CSRF, Kit, LearningActivity, MemoryFormat, Paths}
  alias Ryker.Ingress
  alias Ryker.{Knowledge, Learning, Settings}
  alias Ryker.Wording
  alias Ryker.Work

  @doc """
  The topics an open Learning page listens to, as the context functions that
  subscribe to them (`Ryker.ControlPlane.WorkbenchLive`): learning's batches,
  passes and notes, the topics they write, the messages waiting to be read,
  the worker sessions learning holds, and the switch in the settings.
  """
  def subscriptions do
    [
      {Learning, :subscribe_learning, []},
      {Knowledge, :subscribe_knowledge, []},
      {Ingress.Inbox, :subscribe_inputs, []},
      {Work.Custody, :subscribe_sessions, []},
      {Settings, :subscribe, []}
    ]
  end

  @doc "The query keys the Learning page reads."
  def query_keys, do: LearningActivity.query_keys()

  @doc """
  The shell's heading for one batch: what it learned from, and the way back
  to all learning. Nil for the list, which keeps the page's own title and its
  switch; `:not_found` for a batch that does not exist.
  """
  @spec heading(map(), map()) :: map() | :not_found | nil
  def heading(%{selected: %{} = batch}, _params),
    do: %{
      title: "Learning from #{batch.conversation}",
      description: nil,
      back: {"All learning", "/memory/learning"}
    }

  def heading(_activity, %{"batch" => _batch}), do: :not_found
  def heading(_activity, _params), do: nil

  @doc """
  The Learning body for a `LearningActivity` projection and the worker
  sessions learning holds open (`WorkspaceProjection.learning_sessions/0`).
  """
  @spec html(map(), [map()], String.t() | nil) :: iodata()
  def html(activity, sessions, csrf_secret) do
    %{
      __changed__: nil,
      activity: activity,
      sessions: sessions,
      csrf_secret: csrf_secret
    }
    |> render()
    |> Safe.to_iodata()
  end

  def render(assigns) do
    ~H"""
    <div class="memory-view memory-learning">
      <%= if @activity.selected do %>
        <.batch batch={@activity.selected} csrf_secret={@csrf_secret} />
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
              link_row
              text={batch.error}
              meta={[
                batch.repository,
                Wording.count(batch.input_count, "message"),
                starts(batch),
                MemoryFormat.time(batch.at),
                MemoryFormat.time(batch[:next_check], "Next check ")
              ]}
            />
          </Kit.entity_list>
          <.pager
            page={@activity.attention.page}
            pages={@activity.attention.pages}
            path={&path(@activity, %{"attention_page" => &1})}
            label="Pages of learning that needs attention"
          />
        </section>
        <section id="recent" class="memory-section">
          <Kit.section_head
            title="Recent"
            lede="Each pass reads new messages from one conversation and updates what Ryker knows. Finding nothing to change is a normal outcome."
          />
          <Kit.toolbar :if={finished_or_running(@activity) > 0}>
            <Kit.segmented label="Show by outcome" options={outcomes(@activity)} />
          </Kit.toolbar>
          <Kit.entity_list :if={@activity.recent.items != []} label="Recent learning">
            <Kit.entity_row
              :for={batch <- @activity.recent.items}
              id={"batch-" <> batch.id}
              icon={:book}
              name={batch.conversation}
              href={batch.path}
              link_row
              state={state(batch.status)}
              text={batch.error}
              meta={[
                batch.repository,
                Wording.count(batch.input_count, "message"),
                MemoryFormat.time(batch.at)
              ]}
            />
          </Kit.entity_list>
          <Kit.empty
            :if={@activity.recent.items == [] and @activity.recent.outcome != ""}
            variant={:hint}
            icon={:search}
            title="Nothing with this outcome yet"
            text="Choose All to see every recent pass."
          />
          <Kit.empty
            :if={@activity.recent.items == [] and @activity.recent.outcome == ""}
            variant={:hint}
            icon={:book}
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
            path={&path(@activity, %{"page" => &1})}
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
            path={&path(@activity, %{"handover_page" => &1})}
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
              id={"session-" <> Kit.dom_id(session.ref)}
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
                  path={Paths.action("retention", session.ref, "rearm")}
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
        {Wording.count(@activity.counts.deferred, "needs attention", "need attention")}
      </a>
    </Kit.status_line>
    <p :if={state_note(@activity.state)} class="memory-note memory-status-note">
      {state_note(@activity.state)}
      <a :if={@activity.state == :cannot_start} href="/settings/advanced">Open Advanced settings</a>
    </p>
    """
  end

  attr(:batch, :map, required: true)
  attr(:csrf_secret, :string, default: nil)

  # One batch's page under the shell's heading (`heading/1`), read the way a
  # failure's page reads: its state, what happened, what you can do, then its
  # attempts. Andrew, 2026-09-27: "this is poorly designed, especially back
  # button you can't even find clearly"; a batch stuck on a topic that lost
  # its messages offered only relearning it, and "why I can't just
  # forget/delete it?". What you can do is there only when something is: why
  # one more start waits is part of what happened.
  defp batch(assigns) do
    assigns =
      assign(assigns,
        retry: assigns.batch.retry_available == true and assigns.csrf_secret != nil,
        drop: assigns.batch[:drop_available] == true
      )

    ~H"""
    <article class="memory-batch" id={"batch-" <> @batch.id}>
      <Kit.status_line id="batch-status" state={state(@batch.status)}>
        <span :if={@batch.completed_at}>{MemoryFormat.time(@batch.completed_at, ended(@batch.status))}</span>
        <span :if={is_nil(@batch.completed_at)}>{MemoryFormat.time(@batch.at, "queued ")}</span>
        <span :if={@batch[:next_check]}>{MemoryFormat.time(@batch.next_check, "next check ")}</span>
      </Kit.status_line>
      <Kit.facts id="batch-facts" facts={batch_facts(@batch)} />
      <Kit.section_head title="What happened" />
      <div class="memory-prose">
        <p>{happened(@batch.status)}</p>
        <p :if={cause(@batch)}>{cause(@batch)}</p>
        <p :if={@batch.retry_blocked}>{@batch.retry_blocked}</p>
      </div>
    </article>
    <section :if={@batch[:learned]} id="learned" class="memory-section">
      <Kit.section_head
        title="What Ryker learned"
        lede="What the model decided, in its own words, and the topics it wrote."
      >
        <:actions :if={@batch.learned.path}>
          <a href={@batch.learned.path}>Open on the Timeline</a>
        </:actions>
      </Kit.section_head>
      <Kit.facts id="learned-reason" facts={[{"Reason", @batch.learned.reason}]} />
      <Kit.entity_list :if={@batch.learned.updates != []} label="Topics">
        <Kit.entity_row
          :for={{update, index} <- Enum.with_index(@batch.learned.updates, 1)}
          id={"learned-#{index}"}
          icon={:book}
          name={update.title}
          href={update.path}
          link_row={not is_nil(update.path)}
          state={update_state(update.action)}
          text={update.summary}
          meta={[update.key && "key " <> update.key]}
        />
      </Kit.entity_list>
    </section>
    <section
      :if={@batch.status == :deferred and (@batch.relearn != [] or @retry or @drop)}
      id="what-you-can-do"
      class="memory-section"
    >
      <Kit.section_head title="What you can do" lede={options_lede(@batch)} />
      <Kit.entity_list label="What you can do">
        <Kit.entity_row
          :for={topic <- @batch.relearn}
          id={"relearn-" <> topic.id}
          name={"Relearn \"#{topic.title}\""}
          text="Ryker relearns the topic from messages you choose that still exist. One more start can then update it with these messages."
        >
          <:actions><a class="ui-button primary" href={topic.path}>Relearn</a></:actions>
        </Kit.entity_row>
        <Kit.entity_row
          :for={topic <- @batch.relearn}
          id={"forget-" <> topic.id}
          name={"Forget \"#{topic.title}\""}
          text="Ryker stops using the topic, erases what it learned and never learns from its messages again. One more start can then read these messages without it."
        >
          <:actions>
            <.action_button path={forget_path(topic.id, @batch.id)} label="Forget topic" />
          </:actions>
        </Kit.entity_row>
        <Kit.entity_row
          :if={@retry}
          id="retry"
          name="Grant one more start"
          text="Ryker reads these same messages again with one more start, using the learning settings in place now. The messages are checked again first. Earlier attempts and the starts they used stay recorded."
        >
          <:actions>
            <form
              class="action-control"
              method="post"
              action={Paths.action("learning", @batch.id, "retry")}
            >
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
          </:actions>
        </Kit.entity_row>
        <Kit.entity_row
          :if={@drop}
          id="drop"
          name="Drop this batch"
          text="Ryker stops trying to learn from these messages and the batch no longer needs you. Nothing Ryker already learned changes, and replies are unaffected."
        >
          <:actions>
            <.action_button path={Paths.action("learning", @batch.id, "drop")} label="Drop batch" />
          </:actions>
        </Kit.entity_row>
      </Kit.entity_list>
    </section>
    <section id="attempts" class="memory-section">
      <Kit.section_head
        title="Attempts"
        lede="Each attempt opens on the Timeline beside the messages it read, with the exact request Ryker sent and the answer it got back."
      />
      <Kit.entity_list :if={@batch.attempts != []} label="Attempts">
        <Kit.entity_row
          :for={attempt <- @batch.attempts}
          id={"attempt-" <> attempt.id}
          name={"Attempt #{attempt.number}"}
          href={attempt.path}
          link_row
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
        variant={:hint}
        icon={:activity}
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
    <Components.disclosure
      :if={@batch.error_code}
      id="batch-technical"
      label="Technical details"
      class="memory-technical"
    >
      <Components.fact_list facts={[
        %{label: "Diagnostic code", value: @batch.error_code, identifier: true}
      ]} />
    </Components.disclosure>
    """
  end

  # A batch that needed a person stopped, and still reads so once dropped;
  # any other finished.
  defp ended(status) when status in [:deferred, :dropped], do: "stopped "
  defp ended(_status), do: "finished "

  # A batch's facts, one per line: where its messages came from and what it
  # spent.
  defp batch_facts(batch) do
    [
      {"Conversation", MemoryFormat.link(batch.conversation, batch.conversation_path)},
      {"Repository", batch.repository},
      {"Messages", Wording.count(batch.input_count, "message")},
      {"Model starts", starts(batch)},
      {"Mode", if(batch.mode == :shadow, do: "Shadow mode")},
      {"Queued", MemoryFormat.time(batch.at)}
    ]
  end

  defp happened(:queued), do: "Ryker has these messages lined up to learn from."
  defp happened(:running), do: "Ryker is reading these messages now."

  defp happened(:applied),
    do: "Ryker read these messages and updated what it knows."

  defp happened(:no_change),
    do: "Ryker read these messages and found nothing to add or change, which is normal."

  defp happened(:deferred), do: "Ryker stopped learning from these messages and needs you."

  defp happened(:superseded) do
    "These messages changed, were removed or expired before Ryker could learn from them, so it did not."
  end

  defp happened(:dropped) do
    "Learning from these messages was dropped. Ryker will not read them again, and nothing it already learned changed."
  end

  # Why it stopped. A batch stopped by topics that lost their messages names
  # them; any other says what its code means.
  defp cause(%{relearn: [topic]}) do
    "Every attempt stopped on \"#{topic.title}\", a learned topic that lost the messages it was learned from. Ryker does not change such a topic."
  end

  defp cause(%{relearn: [_, _ | _] = topics}) do
    "Every attempt stopped on #{Enum.map_join(topics, ", ", &"\"#{&1.title}\"")}, learned topics that lost the messages they were learned from. Ryker does not change such topics."
  end

  defp cause(batch), do: batch.error

  defp options_lede(%{relearn: [_ | _]}) do
    "Every start stops on a learned topic that lost its messages. Relearn or forget it first, or drop this batch."
  end

  defp options_lede(%{retry_available: true}),
    do: "One more start may work if what stopped the attempts has changed."

  defp options_lede(_batch), do: nil

  # Forgetting a topic from a batch's page asks first, then comes back here.
  defp forget_path(topic_id, batch_id) do
    Paths.query(Paths.action("knowledge", topic_id, "forget"), %{
      "back" => LearningActivity.path(batch_id)
    })
  end

  defp state_word(:on), do: {:on, "Learning is on"}
  defp state_word(:starting), do: {:busy, "Learning is starting"}
  defp state_word(:paused), do: {:warn, "Learning is paused"}
  defp state_word(:not_running), do: {:warn, "Learning is not running here"}
  defp state_word(:cannot_start), do: {:warn, "Learning can't start"}
  defp state_word(:off), do: {:off, "Learning is off"}

  defp state_note(:off) do
    "Ryker keeps new messages but learns nothing from them until learning is on. What it already learned stays available."
  end

  defp state_note(:starting),
    do: "Ryker is applying the change. New messages are learned from once it runs."

  defp state_note(:cannot_start),
    do: "Learning is turned on, but Ryker has no worker or model to learn with yet."

  defp state_note(:not_running) do
    "Learning is set up, but its worker is not running in this Ryker process. New messages wait until it runs."
  end

  defp state_note(:paused) do
    "The worker reported more access than learning allows, so Ryker sends it nothing. Check the worker's version. New messages wait until it's fixed."
  end

  defp state_note(_state), do: nil

  defp waiting(0), do: "No messages waiting"
  defp waiting(count), do: Wording.count(count, "message") <> " waiting"

  # How many model starts a batch used. The limit is part of it only while
  # the batch can still start: a stopped batch keeps none of the starts it
  # did not use, so "1 of 3" there promised two that would never run.
  defp starts(%{status: status} = batch) when status in [:queued, :running] do
    "#{batch.start_count} of #{Wording.count(batch.start_limit, "model start")} used"
  end

  defp starts(%{start_count: 0}), do: "No model starts used"

  defp starts(batch),
    do: Wording.count(batch.start_count, "model start") <> " used"

  defp state(:queued), do: {:off, LearningActivity.label(:queued)}
  defp state(:running), do: {:busy, LearningActivity.label(:running)}
  defp state(:applied), do: {:on, LearningActivity.label(:applied)}
  defp state(:no_change), do: {:off, LearningActivity.label(:no_change)}
  defp state(:deferred), do: {:warn, LearningActivity.label(:deferred)}
  defp state(:superseded), do: {:off, LearningActivity.label(:superseded)}
  defp state(:dropped), do: {:off, LearningActivity.label(:dropped)}

  defp attempt_state(%{status: status, label: label}) when status in [:rejected, :stale],
    do: {:warn, label}

  defp attempt_state(%{status: :prepared, label: label}), do: {:busy, label}
  defp attempt_state(%{label: "Knowledge updated" = label}), do: {:on, label}
  defp attempt_state(%{label: label}), do: {:off, label}

  # Only a list with something in it is worth filtering.
  defp finished_or_running(activity),
    do: activity.counts |> Map.drop([:deferred]) |> Map.values() |> Enum.sum()

  defp outcomes(activity) do
    [{"All", ""} | Enum.map(LearningActivity.outcomes(), &{outcome_label(&1), &1})]
    |> Enum.map(fn {label, outcome} ->
      {label, path(activity, %{"outcome" => outcome, "page" => 1}),
       outcome == activity.recent.outcome}
    end)
  end

  defp outcome_label("updated"), do: "Updated"
  defp outcome_label("no_change"), do: "No change"
  defp outcome_label("in_progress"), do: "In progress"
  defp outcome_label("sources_changed"), do: "Sources changed"

  # Each list pages on its own, and the outcome chosen stays: every pager built its
  # links from nothing, so paging one list sent the others back to their first page
  # and dropped the outcome (2026-10-04 review).
  defp path(activity, changes) do
    %{
      "attention_page" => activity.attention.page,
      "page" => activity.recent.page,
      "handover_page" => activity.handover_failures.page,
      "outcome" => activity.recent.outcome
    }
    |> Map.merge(changes)
    |> Enum.reject(fn {_key, value} -> value in [1, ""] end)
    |> then(&Paths.query("/memory/learning", &1))
  end

  # What an attempt did to one topic.
  defp update_state("create"), do: {:on, "Created"}
  defp update_state("update"), do: {:on, "Updated"}
  defp update_state("defer"), do: {:off, "Left as it was"}
  defp update_state(_action), do: nil

  defp attempts_path(batch, page),
    do: Paths.query("/memory/learning", batch: batch.id, attempt_page: page) <> "#attempts"

  # Worker sessions, worded the way the Working copies page used to word them
  # when learning sessions were listed there.
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
  defp session_detail(%{learning_state: :retry_scheduled, learning_retry_at: %DateTime{} = at}) do
    sentence([
      "The worker has not confirmed that this session stopped. Ryker checks again ",
      MemoryFormat.time(at),
      "."
    ])
  end

  defp session_detail(%{learning_state: :retry_scheduled}),
    do: "The worker has not confirmed that this session stopped. Ryker checks again on its own."

  defp session_detail(%{learning_state: :checking_worker}),
    do: "Ryker is confirming whether the worker session stopped."

  defp session_detail(%{learning_state: :cleanup_pending}),
    do: "Learning is done with this session. Cleanup is next."

  defp session_detail(%{status: :blocked, summary: "coop_error"}) do
    "The worker couldn't finish this step. Its error is saved here; check it before you try again."
  end

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
end
