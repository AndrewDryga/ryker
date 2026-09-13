defmodule Responder.ControlPlane.ChannelPage do
  @moduledoc """
  The Channel detail body: single-column sections under the shared page header.

  The route owns the title and the one-line description (`description/1`);
  the body never renders a competing heading. Raw Slack IDs and canonical refs
  stay visible beside every resolved name so an empty section can never hide
  a scope mismatch behind a friendly label.
  """
  use Phoenix.Component
  import Responder.ControlPlane.Components, only: [label: 1, timestamp: 1]
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
        noun="schedule"
        empty="No schedules target this channel."
      >
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
      </.relation>
      <.relation
        id="episodes"
        base={@base}
        params={@view.params}
        title="Related episodes"
        relation={@view.episodes}
        noun="episode"
        empty="No episodes were delivered to this channel."
      >
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
      </.relation>
      <.relation
        id="summaries"
        base={@base}
        params={@view.params}
        title="Conversation summaries"
        relation={@view.summaries}
        noun="summary"
        empty="No conversation summaries are retained for this channel."
      >
        <table>
          <thead>
            <tr>
              <th>Summary</th><th>Thread</th><th>Repository</th><th>Updated</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={item <- @view.summaries.items}>
              <td><code>{item.ref}</code></td>
              <td>{item.thread_ref || "Channel root"}</td>
              <td>{item.repository_ref || "None"}</td>
              <td>{timestamp(item.updated_at)}</td>
            </tr>
          </tbody>
        </table>
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
  attr(:title, :string, required: true)
  attr(:relation, :map, required: true)
  attr(:noun, :string, required: true)
  attr(:empty, :string, required: true)
  attr(:base, :string, required: true)
  attr(:params, :map, required: true)
  slot(:inner_block, required: true)

  defp relation(assigns) do
    ~H"""
    <section id={@id} class="channel-section">
      <header class="channel-section-heading">
        <h2>{@title}</h2><span class="channel-count">{count(@relation.total, @noun)}</span>
      </header>
      <p :if={@relation.total == 0} class="empty-state">{@empty}</p>
      <div :if={@relation.items != []} class="table-wrap">{render_slot(@inner_block)}</div>
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

  defp count(1, noun), do: "1 #{noun}"
  defp count(total, "summary"), do: "#{total} summaries"
  defp count(total, noun), do: "#{total} #{noun}s"

  defp encode(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
