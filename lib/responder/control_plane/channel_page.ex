defmodule Responder.ControlPlane.ChannelPage do
  @moduledoc """
  The Channel detail body: single-column sections under the shared page header.

  The route owns the title and the one-line description (`description/1`);
  the body never renders a competing heading. Raw Slack IDs and canonical refs
  stay visible beside every resolved name so an empty section can never hide
  a scope mismatch behind a friendly label.
  """
  use Phoenix.Component

  import Responder.ControlPlane.Components,
    only: [label: 1, page_help: 1, result_count: 1, timestamp: 1]

  alias Responder.ControlPlane.{Activity, ChannelScope, SlackNames}

  attr(:view, :map, required: true)

  def render(assigns) do
    assigns = assign(assigns, :base, base_path(assigns.view.scope))

    ~H"""
    <div class="channel-page">
      <p class="channel-metrics">
        <a href={Activity.conversation_path("slack", @view.scope.conversation_ref)}>
          {count(@view.episodes.total, "episode")}
        </a>
        <span>retained for this conversation, in every mode</span>
      </p>
      <.page_help id="channel-help" label="How context reaches this channel">
        <p>
          Rules apply only where they were confirmed. Preferences, guidance and memory reach this
          channel through its exact conversation, the repository configured here, or the whole
          workspace, and each entry says which. Entries visible only in the conversation that
          confirmed them never appear elsewhere. Paused, expired and archived entries are not in
          effect and are listed in their library instead; opening this page recalls nothing.
        </p>
      </.page_help>
      <section id="configuration" class="channel-section">
        <h2>Configuration</h2>
        <dl class="channel-facts">
          <.fact label="Workspace">
            {SlackNames.name(@view.scope.workspace_ref, @view.scope.workspace_ref)}
            <code>{@view.scope.workspace_ref}</code>
            <code>{@view.scope.canonical_workspace_ref}</code>
          </.fact>
          <.fact label="Channel">
            {SlackNames.name(@view.scope.workspace_ref, @view.scope.channel_ref)}
            <code>{@view.scope.channel_ref}</code>
            <code>{@view.scope.conversation_ref}</code>
          </.fact>
          <.fact label="Kind">{kind(@view.channel.kind)}</.fact>
          <.fact label="Membership">{membership(@view.channel.membership)}</.fact>
          <.fact label="Visibility">
            {tri_state(@view.channel.membership, :private, "Private", "Public")}
          </.fact>
          <.fact label="Externally shared">
            {tri_state(@view.channel.membership, :external_shared, "Yes", "No")}
          </.fact>
          <.fact label="Participation">
            {configured(@view.channel.configuration, :participation, &label/1)}
          </.fact>
          <.fact label="Repository">{repository(@view.channel.repository)}</.fact>
          <.fact label="Alert policy">
            {configured(@view.channel.configuration, :alert_policy, &label/1)}
          </.fact>
          <.fact label="Additional users">
            {configured_list(@view.channel.configuration, :invite_user_refs, &person(&1, @view.scope))}
          </.fact>
          <.fact label="User groups">
            {configured_list(
              @view.channel.configuration,
              :invite_user_group_refs,
              &Function.identity/1
            )}
          </.fact>
          <.fact label="Configured by">
            {configured(@view.channel.configuration, :actor_ref, &person(&1, @view.scope))}
          </.fact>
          <.fact label="Revision">
            {configured(@view.channel.configuration, :revision, &Integer.to_string/1)}
          </.fact>
          <.fact label="Saved">
            {configured(@view.channel.configuration, :saved_at, &timestamp/1)}
          </.fact>
          <%= if @view.channel.incident_room do %>
            <.fact label="Incident room">
              <a href={"/incident-rooms/" <> encode(@view.channel.incident_room.ref)}>
                {@view.channel.incident_room.title}
              </a>
              · {label(@view.channel.incident_room.status)}
            </.fact>
            <.fact label="Room state">{label(@view.channel.incident_room.channel_state)}</.fact>
            <.fact label="Requested as">
              {if @view.channel.incident_room.private, do: "Private", else: "Public"}
            </.fact>
            <.fact :if={@view.channel.incident_room.episode_ref} label="Investigation">
              <a href={"/timeline/" <> encode(@view.channel.incident_room.episode_ref)}>
                {@view.channel.incident_room.episode_ref}
              </a>
            </.fact>
          <% end %>
        </dl>
      </section>
      <section id="participation" class="channel-section">
        <h2>Effective participation</h2>
        <p :if={is_nil(@view.participation)} class="channel-unavailable">
          The effective participation could not be resolved for this conversation.
        </p>
        <div :if={@view.participation} class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Setting</th><th>Value</th><th>Decided by</th><th>Revision</th><th>Updated</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={item <- @view.participation}>
                <td>{label(item.setting)}</td>
                <td>{if item.value, do: "On", else: "Off"}</td>
                <td>{decided_by(item.scope)}</td>
                <td>{item.revision || "—"}</td>
                <td>{timestamp(item.updated_at)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
      <.relation
        id="schedules"
        base={@base}
        params={@view.params}
        title="Schedules"
        relation={@view.schedules}
        one="schedule"
        many="schedules"
        empty="No schedules target this channel."
      >
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Schedule</th><th>Status</th><th>Next run</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={item <- @view.schedules.items}>
                <td><a href={"/schedules/" <> encode(item.ref)}>{item.title}</a></td>
                <td>{label(item.status)}</td>
                <td>{timestamp(item.next_occurrence_at)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </.relation>
      <.relation
        id="episodes"
        base={@base}
        params={@view.params}
        title="Related episodes"
        relation={@view.episodes}
        one="episode"
        many="episodes"
        empty="No episodes were delivered to this channel."
      >
        <div class="table-wrap">
          <table>
            <thead>
              <tr>
                <th>Episode</th><th>State</th><th>Mode</th><th>Thread</th><th>Updated</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={item <- @view.episodes.items}>
                <td><a href={"/timeline/" <> encode(item.ref)}><code>{item.ref}</code></a></td>
                <td>{label(item.state)}</td>
                <td>{label(item.execution_mode)}</td>
                <td>{item.thread_ref || "Channel root"}</td>
                <td>{timestamp(item.updated_at)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </.relation>
      <.relation
        id="summaries"
        base={@base}
        params={@view.params}
        title="Conversation summaries"
        relation={@view.summaries}
        one="summary"
        many="summaries"
        empty="No conversation summaries are retained for this channel."
      >
        <:health>
          <p
            :if={@view.continuity.drafts > 0 or @view.continuity.handover_failures > 0}
            class="channel-health"
          >
            <span :if={@view.continuity.drafts > 0}>
              {count(@view.continuity.drafts, "summary draft", "summary drafts")} in flight
            </span>
            <a :if={@view.continuity.handover_failures > 0} href="/memory#handover-failures">
              {count(@view.continuity.handover_failures, "handover", "handovers")} not saved →
            </a>
          </p>
        </:health>
        <article
          :for={item <- @view.summaries.items}
          class="channel-entry"
          id={"summary-" <> item.ref}
        >
          <header>
            <h3>{item.title}</h3>
            <time datetime={DateTime.to_iso8601(item.updated_at)}>{timestamp(item.updated_at)}</time>
          </header>
          <p class="channel-entry-meta">
            <span>{if item.thread_ref, do: "Thread " <> item.thread_ref, else: "Channel root"}</span>
            <span :if={item.repository_ref}>{item.repository_ref}</span>
            <span>{recalled(item)}</span>
          </p>
          <p :if={item.recall_warning} class="channel-unavailable">
            Not used for recall · {if item.recall_warning == :missing_source_history,
              do: "no complete source history was saved.",
              else: "source history is invalid."} Kept for inspection.
          </p>
          <p :if={item.maintenance_error} class="channel-unavailable">
            Handover maintenance: {item.maintenance_error}
            <span :if={item.maintenance_retry_at}>
              Next check {timestamp(item.maintenance_retry_at)}.
            </span>
          </p>
          <p :if={item.text != ""} class="channel-entry-text">{item.text}</p>
          <.facts
            id={"summary-" <> item.ref <> "-facts"}
            groups={item.groups}
            label="Decisions, open work and questions"
          />
          <footer>
            <a :if={item.request_path} href={item.request_path}>Source request →</a>
            <a :if={item.source} href={item.source} rel="noopener noreferrer">Source message →</a>
            <span :if={item.expires_at}>Retained until {timestamp(item.expires_at)}</span>
            <code>{item.ref}</code>
          </footer>
        </article>
      </.relation>
      <.relation
        id="rollups"
        base={@base}
        params={@view.params}
        title="Conversation rollups"
        relation={@view.rollups}
        one="rollup"
        many="rollups"
        empty="No compacted continuity is retained for this channel."
      >
        <article :for={item <- @view.rollups.items} class="channel-entry" id={"rollup-" <> item.ref}>
          <header>
            <h3>{item.title}</h3>
            <time datetime={DateTime.to_iso8601(item.period_end)}>
              {timestamp(item.period_start)} – {timestamp(item.period_end)}
            </time>
          </header>
          <p class="channel-entry-meta">
            <span>{count(item.source_count, "source", "sources")}</span>
            <span :if={item.repository_ref}>{item.repository_ref}</span>
            <span>{recalled(item)}</span>
            <span>Expires {timestamp(item.expires_at)}</span>
          </p>
          <p :if={item.text != ""} class="channel-entry-text">{item.text}</p>
          <.facts
            id={"rollup-" <> item.ref <> "-facts"}
            groups={item.groups}
            label="Decisions, open work and questions"
          />
          <footer><code>{item.ref}</code></footer>
        </article>
      </.relation>
      <.relation
        id="knowledge"
        base={@base}
        params={@view.params}
        title="Learned knowledge"
        relation={@view.knowledge}
        one="topic"
        many="topics"
        empty="Nothing has been learned from this channel yet."
      >
        <article
          :for={item <- @view.knowledge.items}
          class="channel-entry"
          id={"knowledge-" <> item.id}
        >
          <header>
            <h3>{item.title}</h3>
            <time datetime={DateTime.to_iso8601(item.updated_at)}>{timestamp(item.updated_at)}</time>
          </header>
          <p :if={!item.available} class="channel-unavailable">
            Not used for recall · a supporting source changed, was removed, or expired.
          </p>
          <p :if={item.text != ""} class="channel-entry-text">{item.text}</p>
          <footer>
            <a href={item.path}>
              Update history · {item.version} {if item.version == 1, do: "revision", else: "revisions"} →
            </a>
            <a :if={item.request_path} href={item.request_path}>Source request →</a>
            <span :if={item.source_at}>Latest source {timestamp(item.source_at)}</span>
            <span :if={item.expires_at}>Retained until {timestamp(item.expires_at)}</span>
          </footer>
        </article>
      </.relation>
      <.relation
        id="learning"
        base={@base}
        params={@view.params}
        title="Learning"
        relation={@view.learning}
        one="batch"
        many="batches"
        empty="No learning batches have been formed from this channel."
      >
        <:health>
          <p class="channel-health">
            <span :if={!@view.learning.enabled}>Learning is disabled</span>
            <span>{@view.learning.counts.queued} queued</span>
            <span>{@view.learning.counts.running} learning</span>
            <span>{@view.learning.counts.deferred} needs attention</span>
            <span>{count(@view.learning.waiting_inputs, "message", "messages")} waiting</span>
          </p>
        </:health>
        <ol class="channel-batches">
          <li :for={batch <- @view.learning.items} id={"batch-" <> batch.id}>
            <div>
              <a href={batch.path}><strong>{batch.label}</strong></a>
              · {count(batch.input_count, "message", "messages")} · {label(batch.mode)}
              <span :if={batch.repository}> · {batch.repository}</span>
            </div>
            <p :if={batch.error} class={learning_note(batch)}>{batch.error}</p>
            <p :if={batch.next_attempt_at}>Next check {timestamp(batch.next_attempt_at)}</p>
            <time datetime={DateTime.to_iso8601(batch.at)}>{timestamp(batch.at)}</time>
          </li>
        </ol>
      </.relation>
      <.relation
        id="rules"
        base={@base}
        params={@view.params}
        title="Standing rules"
        relation={@view.rules}
        one="rule"
        many="rules"
        empty="No standing rules target this channel."
      >
        <article :for={item <- @view.rules.items} class="channel-entry" id={"rule-" <> item.ref}>
          <header>
            <h3>{item.title}</h3>
            <span class={"ui-status status-#{if item.status == "active", do: "done", else: "quiet"}"}>
              {if item.status == "active", do: "Active", else: "Paused"}
            </span>
          </header>
          <p class="channel-entry-meta">
            <span>When: {label(item.trigger || "Source event")}</span>
            <span :if={item.source_filter}>From: {sender(item.source_filter)}</span>
            <span :if={item.repository}>{item.repository}</span>
            <span>{expiry(item.expires_at)}</span>
            <span>{used(item)}</span>
          </p>
          <p :if={item.task} class="channel-entry-text">{item.task}</p>
          <footer>
            <a href={item.library_path}>Open in Standing rules →</a>
            <a :if={item.source_url} href={item.source_url} rel="noopener noreferrer">
              Original conversation →
            </a>
            <span>Confirmed {timestamp(item.confirmed_at)}</span>
          </footer>
        </article>
      </.relation>
      <.relation
        id="preferences"
        base={@base}
        params={@view.params}
        title="Preferences"
        relation={@view.preferences}
        one="preference"
        many="preferences"
        empty="No confirmed preferences apply here. Responder is using its defaults."
      >
        <article
          :for={item <- @view.preferences.items}
          class="channel-entry"
          id={"preference-" <> item.ref}
        >
          <header>
            <h3>{label(item.key || "Preference")}</h3>
            <span class="channel-scope">{scope(item)}</span>
          </header>
          <p class="channel-entry-text">{label(item.value || "Not recorded")}</p>
          <p class="channel-entry-meta">
            <span>{expiry(item.expires_at)}</span>
            <span>{used(item)}</span>
          </p>
          <footer>
            <a href={item.library_path}>Open in Preferences →</a>
            <a :if={item.source_url} href={item.source_url} rel="noopener noreferrer">
              Original conversation →
            </a>
            <span>Confirmed {timestamp(item.confirmed_at)}</span>
          </footer>
        </article>
      </.relation>
      <.relation
        id="guidance"
        base={@base}
        params={@view.params}
        title="Guidance"
        relation={@view.guidance}
        one="guidance entry"
        many="guidance entries"
        empty="No confirmed guidance is recalled here."
      >
        <article
          :for={item <- @view.guidance.items}
          class="channel-entry"
          id={"guidance-" <> item.ref}
        >
          <header>
            <h3>{item.title}</h3>
            <span class="channel-scope">{scope(item)}</span>
          </header>
          <p class="channel-entry-meta">
            <span>{visibility(item.visibility)}</span>
            <span>{expiry(item.expires_at)}</span>
            <span>{used(item)}</span>
          </p>
          <p :if={item.summary} class="channel-entry-text">{item.summary}</p>
          <details
            :if={item.text}
            id={"guidance-" <> item.ref <> "-text"}
            class="channel-facts-disclosure"
          >
            <summary>Full guidance</summary>
            <p class="channel-entry-text">{item.text}</p>
          </details>
          <footer>
            <a href={item.library_path}>Open in Guidance →</a>
            <a :if={item.source_url} href={item.source_url} rel="noopener noreferrer">
              Original conversation →
            </a>
            <span>Confirmed {timestamp(item.confirmed_at)}</span>
          </footer>
        </article>
      </.relation>
      <.relation
        id="memory"
        base={@base}
        params={@view.params}
        title="Operational memory"
        relation={@view.memory}
        one="memory"
        many="memories"
        empty="No confirmed operational memory applies here."
      >
        <article :for={item <- @view.memory.items} class="channel-entry" id={"memory-" <> item.ref}>
          <header>
            <h3>{item.subject}</h3>
            <span class="channel-scope">{scope(item)}</span>
          </header>
          <p class="channel-entry-text">{item.value || "Not recorded"}</p>
          <p class="channel-entry-meta">
            <span>{label(item.kind)}</span>
            <span>{visibility(item.visibility)}</span>
            <span :if={item.applicability}>{item.applicability}</span>
            <span>{expiry(item.expires_at)}</span>
            <span>{recalled(item)}</span>
          </p>
          <footer>
            <a href={item.library_path}>Open in Memory →</a>
            <a :if={item.source_url} href={item.source_url} rel="noopener noreferrer">
              Original conversation →
            </a>
            <span>Confirmed {timestamp(item.confirmed_at)}</span>
          </footer>
        </article>
      </.relation>
    </div>
    """
  end

  attr(:label, :string, required: true)
  slot(:inner_block, required: true)

  defp fact(assigns) do
    ~H"""
    <div>
      <dt>{@label}</dt><dd>{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  attr(:id, :string, required: true)
  attr(:groups, :list, required: true)
  attr(:label, :string, required: true)

  # A stable id keeps the disclosure open across a live refresh even when the
  # rows around it move.
  defp facts(assigns) do
    ~H"""
    <details :if={@groups != []} id={@id} class="channel-facts-disclosure">
      <summary>{@label}</summary>
      <div :for={{heading, values} <- @groups} class="channel-fact-group">
        <h4>{heading}</h4>
        <ul>
          <li :for={value <- values}>{value}</li>
        </ul>
      </div>
    </details>
    """
  end

  attr(:id, :string, required: true)
  attr(:title, :string, required: true)
  attr(:relation, :map, required: true)
  attr(:one, :string, required: true)
  attr(:many, :string, required: true)
  attr(:empty, :string, required: true)
  attr(:base, :string, required: true)
  attr(:params, :map, required: true)
  slot(:health, doc: "Aggregate state of the relation that is not itself a row")
  slot(:inner_block, required: true)

  defp relation(assigns) do
    ~H"""
    <section id={@id} class="channel-section">
      <h2>{@title}</h2>
      <.result_count count={@relation.total} one={@one} many={@many} />
      {render_slot(@health)}
      <p :if={@relation.total == 0} class="empty-state">{@empty}</p>
      <div :if={@relation.items != []} class="channel-relation">{render_slot(@inner_block)}</div>
      <nav :if={@relation.pages > 1} class="pagination" aria-label={"#{@title} pages"}>
        <a
          :if={@relation.page > 1}
          href={page_path(@base, @params, @relation, @relation.page - 1, @id)}
        >
          ← Previous
        </a>
        <span>Page {@relation.page} of {@relation.pages}</span>
        <a
          :if={@relation.page < @relation.pages}
          href={page_path(@base, @params, @relation, @relation.page + 1, @id)}
        >
          Next →
        </a>
      </nav>
    </section>
    """
  end

  defp base_path(%ChannelScope{} = scope),
    do: "/channels/" <> encode(scope.workspace_ref) <> "/" <> encode(scope.channel_ref)

  # One pager link carries every other section's resolved page and lands on
  # its own anchor, so paging summaries never resets episodes.
  defp page_path(base, params, relation, page, anchor) do
    params =
      if page > 1,
        do: Map.put(params, relation.key, Integer.to_string(page)),
        else: Map.delete(params, relation.key)

    query = if params == %{}, do: "", else: "?" <> URI.encode_query(params)
    base <> query <> "#" <> anchor
  end

  @doc "The one-line description the route hands to the shared page header."
  @spec description(map()) :: String.t()
  def description(view) do
    name = SlackNames.name(view.scope.workspace_ref, view.scope.channel_ref)
    workspace = SlackNames.name(view.scope.workspace_ref, view.scope.workspace_ref)

    joined =
      case view.channel.membership do
        %{status: :joined} -> "Responder is a member."
        %{status: :left} -> "Responder has left."
        %{status: :deleted} -> "The channel was deleted."
        nil -> "No membership is recorded."
      end

    "#{kind(view.channel.kind)} #{name} in #{workspace}. #{joined}"
  end

  defp kind(:incident_room), do: "Incident room"
  defp kind(:direct_message), do: "Direct message"
  defp kind(_channel), do: "Channel"

  defp membership(nil), do: "Not recorded"

  defp membership(%{status: :joined} = membership),
    do: "Joined · generation #{membership.generation} · since #{timestamp(membership.joined_at)}"

  defp membership(%{status: :left} = membership),
    do: "Left · generation #{membership.generation} · left #{timestamp(membership.left_at)}"

  defp membership(%{status: :deleted} = membership),
    do:
      "Deleted · generation #{membership.generation} · deleted #{timestamp(membership.deleted_at)}"

  # false is a recorded value. Only a missing record or a missing field is unknown.
  defp tri_state(nil, _field, _when_true, _when_false), do: "Not recorded"

  defp tri_state(membership, field, when_true, when_false) do
    case Map.fetch!(membership, field) do
      true -> when_true
      false -> when_false
      nil -> "Not recorded"
    end
  end

  defp configured(nil, _field, _present), do: "Not configured"

  defp configured(configuration, field, present) do
    case Map.fetch!(configuration, field) do
      nil -> "Not configured"
      value -> present.(value)
    end
  end

  # An audience nobody added is empty whether or not the channel was configured.
  defp configured_list(nil, _field, _present), do: "None"

  defp configured_list(configuration, field, present) do
    case Map.fetch!(configuration, field) do
      [] -> "None"
      values -> Enum.map_join(values, ", ", present)
    end
  end

  defp repository(nil), do: "Not configured"
  defp repository(%{ref: ref, source: :configuration}), do: "#{ref} · channel configuration"
  defp repository(%{ref: ref, source: :incident_room}), do: "#{ref} · from the incident room"

  defp person(ref, %ChannelScope{workspace_ref: workspace}), do: SlackNames.name(workspace, ref)

  defp decided_by(:channel), do: "This channel"
  defp decided_by(:installation), do: "Installation default"
  defp decided_by(other), do: label(other)

  defp count(total, noun), do: count(total, noun, noun <> "s")
  defp count(1, one, _many), do: "1 #{one}"
  defp count(total, _one, many), do: "#{total} #{many}"

  defp recalled(%{recall_count: 0}), do: "Never recalled"

  defp recalled(%{recall_count: count, last_recalled_at: at}),
    do: "Recalled #{count} #{if count == 1, do: "time", else: "times"} · last #{timestamp(at)}"

  defp learning_note(%{status: :deferred}), do: "channel-unavailable"
  defp learning_note(_batch), do: "channel-entry-meta"

  defp scope(%{scope: :conversation}), do: "This channel"
  defp scope(%{scope: :repository, scope_ref: ref}), do: "Inherited from repository #{ref}"
  defp scope(%{scope: :workspace}), do: "Inherited from the workspace"
  defp scope(%{scope: :global}), do: "Every workspace"

  defp visibility(value) when value in ["workspace", :workspace],
    do: "Visible across the workspace"

  defp visibility(value) when value in ["global", :global], do: "Visible everywhere"
  defp visibility(_conversation_or_private), do: "Visible only in this conversation"

  defp expiry(nil), do: "No expiry"
  defp expiry(expires_at), do: "Expires #{timestamp(expires_at)}"

  defp used(%{use_count: 0}), do: "Used 0 times"

  defp used(%{use_count: count, last_used_at: at}),
    do: "Used #{count} #{if count == 1, do: "time", else: "times"} · last #{timestamp(at)}"

  defp sender("human"), do: "People only"
  defp sender("app"), do: "Apps only"
  defp sender("any"), do: "People and apps"
  defp sender(_), do: "Not recorded"

  defp encode(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
