defmodule Ryker.ControlPlane.ChannelPage do
  @moduledoc """
  One channel's page under the shared header: how Ryker takes part here, the
  channel's instructions, what applies here, what Ryker knows, schedules,
  recent work and usage, each a Kit section. The channel's environment, the
  code and Emisar account its work uses, is chosen here.

  The live shell places the channel's instruction editor between `lead/1`
  and `render/1`, so the page reads in that order. Lists never show raw
  Slack ids or refs; the ones support needs sit in one closed Details
  disclosure under "How Ryker takes part". Every list keeps its own page
  parameter and anchor, so paging one never resets another.
  """
  use Phoenix.Component

  alias Ryker.ControlPlane.{
    Activity,
    ChannelScope,
    ChannelsPage,
    Components,
    Kit,
    ShortTime,
    SlackNames
  }

  attr(:view, :map, required: true)
  attr(:now, :any, default: nil)
  attr(:editor, :boolean, default: true, doc: "Whether the live editor follows the lead")

  attr(:notice, :any,
    default: nil,
    doc: "{tone, message} from the last environment choice on this page, or nil"
  )

  @doc """
  The channel's state, how Ryker takes part here, and the heading of the
  instructions the live editor fills in beneath.
  """
  def lead(assigns) do
    assigns =
      assigns
      |> defaults()
      |> assign_new(:notice, fn -> nil end)
      |> assign(:state, state(assigns.view))

    ~H"""
    <div class="channel-page channel-lead">
      <p :if={@state} class="channel-state">
        <Kit.state tone={elem(@state, 0)} word={elem(@state, 1)} />
      </p>
      <.taking_part view={@view} now={@now} notice={@notice} />
      <Kit.section_head
        id="channel-instructions"
        title="Instructions"
        lede="What Ryker should do differently in this channel. It follows the global instructions everywhere."
      />
      <p :if={!@editor} class="channel-note">
        This channel's instructions could not be loaded. Reload the page to edit them.
      </p>
    </div>
    """
  end

  attr(:view, :map, required: true)
  attr(:now, :any, default: nil)

  @doc "Everything after the instructions editor."
  def render(assigns) do
    assigns = defaults(assigns)

    ~H"""
    <div class="channel-page">
      <.applies view={@view} base={@base} now={@now} />
      <.knows view={@view} base={@base} now={@now} />
      <.schedules view={@view} base={@base} now={@now} />
      <.work view={@view} base={@base} now={@now} />
      <.usage view={@view} />
    </div>
    """
  end

  defp defaults(assigns) do
    assigns
    |> assign_new(:now, fn -> nil end)
    |> assign_new(:editor, fn -> true end)
    |> then(&assign(&1, now: &1.now || DateTime.utc_now(), base: base_path(&1.view.scope)))
  end

  @doc "The one-sentence description the route hands to the shared page header."
  @spec description(map()) :: String.t()
  def description(view) do
    workspace = SlackNames.name(view.scope.workspace_ref, view.scope.workspace_ref)
    membership = view.channel.membership || %{}

    shared =
      if Map.get(membership, :external_shared) == true,
        do: ", shared with another organization",
        else: ""

    case view.channel.kind do
      :direct_message ->
        "A direct message in #{workspace}."

      kind ->
        "#{kind_words(Map.get(membership, :private), kind)} in #{workspace}#{shared}."
    end
  end

  defp kind_words(true, kind), do: "A private " <> kind_word(kind)
  defp kind_words(false, kind), do: "A public " <> kind_word(kind)
  defp kind_words(_unrecorded, :incident_room), do: "An incident room"
  defp kind_words(_unrecorded, _channel), do: "A channel"

  defp kind_word(:incident_room), do: "incident room"
  defp kind_word(_channel), do: "channel"

  defp state(view) do
    room = view.channel.incident_room

    ChannelsPage.state(
      view.channel.membership && view.channel.membership.status,
      is_map(room) and room.status != :closed and room.channel_state not in [:archived, :deleted],
      view.scope.channel_ref
    )
  end

  attr(:view, :map, required: true)
  attr(:now, :any, required: true)
  attr(:notice, :any, default: nil)

  defp taking_part(assigns) do
    assigns =
      assign(assigns,
        configuration: assigns.view.channel.configuration,
        membership: assigns.view.channel.membership,
        room: assigns.view.channel.incident_room,
        environment: assigns.view.channel.environment
      )

    ~H"""
    <section id="taking-part" class="channel-section">
      <Kit.section_head
        title="How Ryker takes part"
        lede="Choose the environment here. To change the rest, type /ryker status in the channel."
      />
      <dl class="channel-facts">
        <.fact label="Conversations">
          <%= if @view.participation do %>
            {ChannelsPage.participation(@view.participation.value)}
            <span class="channel-fact-note">· {decided(@view.participation.source)}</span>
          <% else %>
            Could not be read right now
          <% end %>
        </.fact>
        <.fact label="Alerts">{alerts(@configuration, @view.participation)}</.fact>
        <.fact :if={@environment.source != :incident_room} label="Environment">
          <.environment_choice
            :if={@configuration}
            view={@view}
            environment={@environment}
            notice={@notice}
          />
          <%= if !@configuration do %>
            <%= if @environment.name do %>
              <strong>{@environment.name}</strong>
              <span class="channel-fact-note">· the default environment</span>
            <% else %>
              None, and no environment is the default
            <% end %>
          <% end %>
        </.fact>
        <.fact label="Code">
          <%= case @environment.repositories do %>
            <% [] -> %>
              None, so Ryker does not read code here
            <% [writable | read_only] -> %>
              Changes
              <strong>{writable.name}</strong><span
                :if={read_only != []}
                class="channel-fact-note"
              > · reads {Enum.map_join(read_only, ", ", & &1.name)}</span><span
                :if={@environment.source == :incident_room}
                class="channel-fact-note"
              > · from the incident room</span>
          <% end %>
        </.fact>
        <.fact :if={@environment.source != :incident_room} label="Emisar">
          <%= if @environment.emisar do %>
            <strong>{@environment.emisar}</strong>
          <% else %>
            None, so Ryker cannot act on running systems here
          <% end %>
        </.fact>
        <.fact :if={@room} label="Incident room">
          <a href={"/incident-rooms/" <> encode(@room.ref)}>{@room.title}</a>
          <span class="channel-fact-note">· {room_status(@room.status)}</span>
          <a :if={@room.episode_ref} href={"/timeline/" <> encode(@room.episode_ref)}>
            Investigation
          </a>
        </.fact>
        <.fact :if={invited?(@configuration)} label="Invites to incident rooms">
          {invited(@configuration, @view.scope)}
        </.fact>
        <.fact label="Membership">{membership(@membership, @now)}</.fact>
      </dl>
      <details id="channel-details" class="entity-details">
        <summary>Details</summary>
        <dl class="channel-facts">
          <.fact label="Workspace ID">
            <code>{@view.scope.workspace_ref}</code>
            <code>{@view.scope.canonical_workspace_ref}</code>
          </.fact>
          <.fact label="Channel ID">
            <code>{@view.scope.channel_ref}</code> <code>{@view.scope.conversation_ref}</code>
          </.fact>
          <.fact label="Visibility">{tri_state(@membership, :private, "Private", "Public")}</.fact>
          <.fact label="Shared with another organization">
            {tri_state(@membership, :external_shared, "Yes", "No")}
          </.fact>
          <.fact label="Channel settings">{saved(@configuration, @view.scope)}</.fact>
          <.fact :if={@membership} label="Membership record">
            Generation {@membership.generation}
          </.fact>
          <.fact :if={@room} label="Incident room ID"><code>{@room.ref}</code></.fact>
        </dl>
      </details>
    </section>
    """
  end

  attr(:view, :map, required: true)
  attr(:environment, :map, required: true)
  attr(:notice, :any, default: nil)

  # The one choice made on this page: which environment the channel's work
  # runs in, or none. The LiveView saves it through the channel's own setting.
  defp environment_choice(assigns) do
    ~H"""
    <form
      id="channel-environment"
      class="settings-inline-form"
      phx-submit="select-channel-environment"
    >
      <input type="hidden" name="workspace" value={@view.scope.workspace_ref} />
      <input type="hidden" name="channel" value={@view.scope.channel_ref} />
      <div class="settings-field">
        <label class="sr-only" for="channel-environment-choice">Environment</label>
        <select id="channel-environment-choice" name="environment">
          <option
            :for={choice <- @view.environments}
            value={choice.ref}
            selected={choice.ref == @environment.ref}
          >
            {choice.name}
          </option>
          <option value="" selected={is_nil(@environment.ref)}>No environment</option>
        </select>
      </div>
      <button type="submit" class="ui-button secondary">Save</button>
    </form>
    <Components.form_feedback
      :if={@notice}
      id="channel-environment-notice"
      message={elem(@notice, 1)}
      tone={elem(@notice, 0)}
    />
    """
  end

  attr(:label, :string, required: true)
  slot(:inner_block, required: true)

  defp fact(assigns) do
    ~H"""
    <div>
      <dt>{@label}</dt>
      <dd>{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  defp decided(:channel), do: "set for this channel"
  defp decided(_installation), do: "workspace default"

  # The same sentences the channel's Slack card uses: watching quietly never
  # starts an investigation, and an unconfigured channel replies in thread.
  defp alerts(_configuration, %{value: :shadow}), do: "Waits to be asked about alerts"

  defp alerts(%{alert_policy: :offer}, _participation),
    do: "Offers to investigate, in the thread or an incident room"

  defp alerts(%{alert_policy: :automatic}, _participation),
    do: "Opens an incident room automatically"

  defp alerts(_reply, _participation), do: "Investigates in the alert's thread"

  defp room_status(:requested), do: "being set up"
  defp room_status(:ready), do: "open"
  defp room_status(:blocked), do: "needs attention"
  defp room_status(:closed), do: "closed"

  defp invited?(%{invite_user_refs: users, invite_user_group_refs: groups}),
    do: users != [] or groups != []

  defp invited?(_configuration), do: false

  defp invited(configuration, %ChannelScope{workspace_ref: workspace}) do
    people = Enum.map(configuration.invite_user_refs, &SlackNames.name(workspace, &1))
    groups = Enum.map(configuration.invite_user_group_refs, &("user group " <> &1))
    Enum.join(people ++ groups, ", ")
  end

  defp membership(nil, _now), do: "Not recorded"

  defp membership(%{status: :joined, joined_at: at}, now),
    do: moment("Ryker joined ", at, now)

  defp membership(%{status: :left, left_at: at}, now), do: moment("Ryker left ", at, now)

  defp membership(%{status: :deleted, deleted_at: at}, now),
    do: moment("The channel was deleted ", at, now)

  defp moment(prefix, nil, _now), do: String.trim(prefix)

  defp moment(prefix, at, now),
    do: ShortTime.time(%{__changed__: nil, at: at, now: now, prefix: prefix})

  # false is a recorded value. Only a missing record or a missing field is unknown.
  defp tri_state(nil, _field, _when_true, _when_false), do: "Not recorded"

  defp tri_state(membership, field, when_true, when_false) do
    case Map.fetch!(membership, field) do
      true -> when_true
      false -> when_false
      nil -> "Not recorded"
    end
  end

  defp saved(nil, _scope), do: "Never saved; this channel follows the defaults"

  defp saved(configuration, scope) do
    by =
      if configuration.actor_ref,
        do: " by " <> SlackNames.name(scope.workspace_ref, configuration.actor_ref),
        else: ""

    "Revision #{configuration.revision}, saved #{Components.timestamp(configuration.saved_at)}#{by}"
  end

  attr(:view, :map, required: true)
  attr(:base, :string, required: true)
  attr(:now, :any, required: true)

  defp applies(assigns) do
    assigns =
      assign(
        assigns,
        :empty,
        Enum.all?(
          [:rules, :preferences, :guidance, :memory],
          &(Map.fetch!(assigns.view, &1).total == 0)
        )
      )

    ~H"""
    <section id="applies" class="channel-section">
      <Kit.section_head
        title="What applies here"
        lede="Rules, saved instructions and facts that reach this channel, and where each one comes from."
      />
      <Kit.empty
        :if={@empty}
        title="Nothing else applies here yet."
        text="Ryker follows the instructions above and its defaults."
      >
        <Kit.ask_hint
          lead="To add a rule, tell Ryker in this channel:"
          example="When someone posts a Terraform plan here, review it for risky changes."
        />
      </Kit.empty>
      <.relation id="rules" base={@base} params={@view.params} relation={@view.rules} many="rules">
        <Kit.entity_row
          :for={item <- @view.rules.items}
          id={"rule-" <> item.ref}
          name={item.title}
          href={item.library_path}
          state={lifecycle(item.status)}
          text={clamp(item.task)}
          meta={[
            "Rule for this channel",
            watches(item.trigger),
            item.source_filter && sender(item.source_filter),
            item.repository && uses(item.repository),
            used(item, @now),
            expiry(item.expires_at, @now)
          ]}
        />
      </.relation>
      <.relation
        id="preferences"
        base={@base}
        params={@view.params}
        relation={@view.preferences}
        many="preferences"
      >
        <Kit.entity_row
          :for={item <- @view.preferences.items}
          id={"preference-" <> item.ref}
          name={Components.label(item.key || "Preference")}
          href={item.library_path}
          text={Components.label(item.value || "Not recorded")}
          meta={["Preference", from(item), used(item, @now), expiry(item.expires_at, @now)]}
        />
      </.relation>
      <.relation
        id="guidance"
        base={@base}
        params={@view.params}
        relation={@view.guidance}
        many="guidance entries"
      >
        <Kit.entity_row
          :for={item <- @view.guidance.items}
          id={"guidance-" <> item.ref}
          name={item.title}
          href={item.library_path}
          text={item.summary}
          meta={[
            "Guidance",
            from(item),
            only_here(item.visibility),
            used(item, @now),
            expiry(item.expires_at, @now)
          ]}
        >
          <:details>
            <details :if={item.text} id={"guidance-" <> item.ref <> "-text"} class="entity-details">
              <summary>Full guidance</summary>
              <p class="channel-entry-text">{item.text}</p>
            </details>
          </:details>
        </Kit.entity_row>
      </.relation>
      <.relation id="memory" base={@base} params={@view.params} relation={@view.memory} many="facts">
        <Kit.entity_row
          :for={item <- @view.memory.items}
          id={"memory-" <> item.ref}
          name={item.subject}
          href={item.library_path}
          text={item.value || "Not recorded"}
          meta={[
            "Fact",
            from(item),
            item.applicability,
            only_here(item.visibility),
            recalled(item),
            expiry(item.expires_at, @now)
          ]}
        />
      </.relation>
    </section>
    """
  end

  attr(:view, :map, required: true)
  attr(:base, :string, required: true)
  attr(:now, :any, required: true)

  defp knows(assigns) do
    ~H"""
    <section id="knows" class="channel-section">
      <Kit.section_head
        title="What Ryker knows"
        lede="Topics Ryker learned here and what it remembers about recent conversations."
      />
      <.learning_health learning={@view.learning} continuity={@view.continuity} />
      <Kit.empty
        :if={@view.knowledge.total == 0 and @view.summaries.total == 0}
        title="Ryker has not learned anything here yet."
        text="It learns from the conversations it can read, even when it does not reply."
      />
      <.relation
        id="knowledge"
        base={@base}
        params={@view.params}
        relation={@view.knowledge}
        many="learned topics"
      >
        <Kit.entity_row
          :for={item <- @view.knowledge.items}
          id={"knowledge-" <> item.id}
          name={item.title}
          href={item.path}
          state={if !item.available, do: {:off, "Not in use"}}
          text={clamp(item.text)}
          meta={[
            "Learned topic",
            if(!item.available, do: "a source changed, was removed or expired"),
            ShortTime.time(%{__changed__: nil, at: item.updated_at, now: @now, prefix: "updated "})
          ]}
        />
      </.relation>
      <.relation
        id="summaries"
        base={@base}
        params={@view.params}
        relation={@view.summaries}
        many="conversation summaries"
      >
        <Kit.entity_row
          :for={item <- @view.summaries.items}
          id={"summary-" <> item.ref}
          name={item.title}
          href={item.request_path}
          state={if item.recall_warning, do: {:off, "Not in use"}}
          text={clamp(item.text)}
          meta={[
            "Conversation summary",
            if(item.thread_ref, do: "in a thread", else: "in the channel"),
            item.repository_ref && uses(item.repository_ref),
            recalled(item),
            ShortTime.time(%{__changed__: nil, at: item.updated_at, now: @now, prefix: "updated "})
          ]}
        >
          <:details>
            <p :if={item.recall_warning} class="channel-note">
              {if item.recall_warning == :missing_source_history,
                do: "Not used: no complete source history was saved. Kept so you can inspect it.",
                else: "Not used: its source history is invalid. Kept so you can inspect it."}
            </p>
            <p :if={item.maintenance_error} class="channel-note">
              Could not update: {item.maintenance_error}
              <ShortTime.time
                :if={item.maintenance_retry_at}
                at={item.maintenance_retry_at}
                now={@now}
                prefix="Next try "
              />
            </p>
            <details id={"summary-" <> item.ref <> "-details"} class="entity-details">
              <summary>Details</summary>
              <p :if={long?(item.text)} class="channel-entry-text">{item.text}</p>
              <div :for={{heading, values} <- item.groups} class="channel-fact-group">
                <h4>{heading}</h4>
                <ul>
                  <li :for={value <- values}>{value}</li>
                </ul>
              </div>
              <p class="channel-links">
                <a :if={item.source} href={item.source} rel="noopener noreferrer">
                  Source message in Slack
                </a>
                <span :if={item.expires_at}>
                  Kept until {Components.timestamp(item.expires_at)}
                </span>
                <code>{item.ref}</code>
              </p>
            </details>
          </:details>
        </Kit.entity_row>
      </.relation>
    </section>
    """
  end

  attr(:learning, :map, required: true)
  attr(:continuity, :map, required: true)

  defp learning_health(assigns) do
    ~H"""
    <p
      :if={
        !@learning.enabled or @learning.waiting > 0 or @learning.needs_attention > 0 or
          @continuity.drafts > 0 or @continuity.handover_failures > 0
      }
      class="channel-health"
    >
      <span :if={!@learning.enabled}>Learning is off</span>
      <span :if={@learning.waiting > 0}>
        {count(@learning.waiting, "message", "messages")} waiting to be learned from
      </span>
      <a :if={@learning.needs_attention > 0} href="/memory/learning">
        {count(@learning.needs_attention, "learning batch needs", "learning batches need")} attention
      </a>
      <span :if={@continuity.drafts > 0}>
        {count(@continuity.drafts, "conversation update", "conversation updates")} being saved
      </span>
      <a :if={@continuity.handover_failures > 0} href="/memory/learning#context-not-saved">
        {count(@continuity.handover_failures, "conversation update", "conversation updates")} could not be saved
      </a>
    </p>
    """
  end

  attr(:view, :map, required: true)
  attr(:base, :string, required: true)
  attr(:now, :any, required: true)

  defp schedules(assigns) do
    ~H"""
    <section id="schedules" class="channel-section">
      <Kit.section_head title="Schedules" lede="Work Ryker runs on a schedule and posts here." />
      <Kit.empty :if={@view.schedules.total == 0} title="Nothing is scheduled here.">
        <Kit.ask_hint
          lead="To add a schedule, tell Ryker in this channel:"
          example="Every weekday at 09:00, summarize open incidents here."
        />
      </Kit.empty>
      <.relation
        id="schedule-list"
        anchor="schedules"
        base={@base}
        params={@view.params}
        relation={@view.schedules}
        many="schedules"
      >
        <Kit.entity_row
          :for={item <- @view.schedules.items}
          id={"schedule-" <> item.ref}
          name={item.title}
          href={"/schedules/" <> encode(item.ref)}
          state={schedule_state(item.status)}
          meta={[
            if(item.status == :active and item.next_occurrence_at,
              do:
                ShortTime.time(%{
                  __changed__: nil,
                  at: item.next_occurrence_at,
                  now: @now,
                  prefix: "next run "
                })
            )
          ]}
        />
      </.relation>
    </section>
    """
  end

  attr(:view, :map, required: true)
  attr(:base, :string, required: true)
  attr(:now, :any, required: true)

  defp work(assigns) do
    assigns =
      assign(
        assigns,
        :activity,
        Activity.conversation_path("slack", assigns.view.scope.conversation_ref)
      )

    ~H"""
    <section id="episodes" class="channel-section">
      <Kit.section_head title="Recent work" lede="What Ryker worked on here, newest first.">
        <:actions :if={@view.episodes.total > 0}>
          <a href={@activity}>
            {if @view.episodes.total == 1,
              do: "Open in Activity",
              else: "All #{@view.episodes.total} conversations"}
          </a>
        </:actions>
      </Kit.section_head>
      <Kit.empty
        :if={@view.episodes.total == 0}
        title="Ryker has not worked here yet."
        text="Mention Ryker in the channel to ask it for something."
      />
      <.relation
        id="episode-list"
        anchor="episodes"
        base={@base}
        params={@view.params}
        relation={@view.episodes}
        many="conversations"
      >
        <Kit.entity_row
          :for={item <- @view.episodes.items}
          id={"episode-" <> item.ref}
          name={item.title || "Untitled request"}
          href={"/timeline/" <> encode(item.ref)}
          state={episode_state(item.state)}
          meta={[
            if(item.thread_ref, do: "in a thread", else: "in the channel"),
            if(item.execution_mode == :shadow, do: "evaluation run"),
            ShortTime.time(%{__changed__: nil, at: item.updated_at, now: @now, prefix: "updated "})
          ]}
        />
      </.relation>
    </section>
    """
  end

  attr(:view, :map, required: true)

  defp usage(assigns) do
    ~H"""
    <section id="usage" class="channel-section">
      <Kit.section_head
        title="Usage"
        lede={window(@view.usage.window) <> ", " <> mode(@view.usage.mode) <> "."}
      >
        <:actions>
          <a href={@view.usage.link}>Requests</a>
          <a href={@view.usage.usage_path}>Usage &amp; cost</a>
        </:actions>
      </Kit.section_head>
      <p :if={@view.usage.executions == 0} class="channel-usage">
        No model work here in this window.
      </p>
      <%= if @view.usage.executions > 0 do %>
        <p class="channel-usage">
          <span>{count(@view.usage.executions, "run", "runs")}</span>
          <span :if={@view.usage.measured > 0}>
            {number(@view.usage.input_tokens)} input, {number(@view.usage.cached_input_tokens)} cached, {number(
              @view.usage.output_tokens
            )} output, {number(@view.usage.reasoning_tokens)} reasoning tokens
          </span>
          <span :if={@view.usage.measured == 0}>Tokens not recorded</span>
          <span>
            {if @view.usage.cost_usd, do: money(@view.usage.cost_usd), else: "Cost not recorded"}
          </span>
        </p>
        <p class="channel-usage-note">
          {@view.usage.measured} of {@view.usage.executions} reported tokens · {@view.usage.costed} of {@view.usage.executions} recorded a cost
        </p>
      <% end %>
    </section>
    """
  end

  attr(:id, :string, required: true)
  attr(:anchor, :string, default: nil, doc: "Where the pager lands; the id by default")
  attr(:relation, :map, required: true)
  attr(:many, :string, required: true)
  attr(:base, :string, required: true)
  attr(:params, :map, required: true)
  slot(:inner_block, required: true)

  # One paged list in a section: its rows, then its own pager, which carries
  # every other list's page and lands back on this list.
  defp relation(assigns) do
    assigns = assign(assigns, :anchor, assigns[:anchor] || assigns.id)

    ~H"""
    <div :if={@relation.total > 0} id={@id} class="channel-relation">
      <Kit.entity_list label={@many}>{render_slot(@inner_block)}</Kit.entity_list>
      <Components.pager
        page={@relation.page}
        pages={@relation.pages}
        path={&page_path(@base, @params, @relation, &1, @anchor)}
        label={"Pages of " <> @many}
        summary={"#{@relation.total} #{@many}"}
      />
    </div>
    """
  end

  defp base_path(%ChannelScope{} = scope),
    do: ChannelsPage.path(scope.workspace_ref, scope.channel_ref)

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

  # A row says what a thing is in a few lines; the whole text is one click
  # away, on the thing's own page or in the row's Details.
  @clamp 280

  defp clamp(text) when is_binary(text) and text != "" do
    if String.length(text) > @clamp,
      do: (text |> String.slice(0, @clamp) |> String.replace(~r/\s+\S*\z/u, "")) <> "…",
      else: text
  end

  defp clamp(_empty), do: nil

  defp long?(text), do: is_binary(text) and String.length(text) > @clamp

  defp lifecycle("active"), do: {:on, "On"}
  defp lifecycle("disabled"), do: {:off, "Paused"}
  defp lifecycle(other), do: {:off, Components.label(other)}

  defp schedule_state(:active), do: {:on, "On"}
  defp schedule_state(:paused), do: {:off, "Paused"}
  defp schedule_state(:completed), do: {:off, "Finished"}
  defp schedule_state(status), do: {:off, Components.label(status)}

  defp episode_state(state) do
    word = Components.label(state)

    case to_string(state) do
      value when value in ~w(pending working delivery_pending) -> {:busy, word}
      value when value in ~w(blocked waiting_for_input) -> {:warn, word}
      "not_started" -> {:bad, word}
      _finished_or_waiting -> {:off, word}
    end
  end

  defp watches("github"), do: "watches GitHub events"
  defp watches("slack"), do: "watches Slack events"
  defp watches("slack_message"), do: "watches Slack messages"
  defp watches(nil), do: nil
  defp watches(trigger), do: "watches " <> String.downcase(Components.label(trigger))

  defp sender("human"), do: "from people only"
  defp sender("app"), do: "from apps only"
  defp sender(_any), do: "from people and apps"

  defp from(%{scope: :conversation}), do: "set for this channel"

  defp from(%{scope: :repository, scope_ref: ref}),
    do: from_repository(%{__changed__: nil, ref: ref})

  defp from(%{scope: :workspace}), do: "from the whole workspace"
  defp from(%{scope: :global}), do: "from every workspace"

  defp from_repository(assigns), do: ~H"from repository <strong>{@ref}</strong>"

  defp uses(repository), do: uses_repository(%{__changed__: nil, ref: repository})
  defp uses_repository(assigns), do: ~H"uses <strong>{@ref}</strong>"

  defp only_here(visibility)
       when visibility in ["conversation", "private", :conversation, :private],
       do: "only in this channel"

  defp only_here(_wider), do: nil

  defp used(%{use_count: 0}, _now), do: "not used yet"

  defp used(%{use_count: count, last_used_at: at}, now) do
    times = if count == 1, do: "used once", else: "used #{count} times"

    if at,
      do: ShortTime.time(%{__changed__: nil, at: at, now: now, prefix: times <> ", last "}),
      else: times
  end

  defp recalled(%{recall_count: 0}), do: "not recalled yet"
  defp recalled(%{recall_count: 1}), do: "recalled once"
  defp recalled(%{recall_count: count}), do: "recalled #{count} times"

  defp expiry(nil, _now), do: nil

  defp expiry(at, now),
    do: ShortTime.time(%{__changed__: nil, at: at, now: now, prefix: "expires "})

  defp count(1, one, _many), do: "1 #{one}"
  defp count(total, _one, many), do: "#{total} #{many}"

  defp window("24h"), do: "Last 24 hours"
  defp window("30d"), do: "Last 30 days"
  defp window("all"), do: "All time"
  defp window(_default), do: "Last 7 days"

  defp mode("live"), do: "live work only"
  defp mode("shadow"), do: "evaluation runs only"
  defp mode(_all), do: "live work and evaluation runs"

  defp number(value) when is_integer(value),
    do: value |> Integer.to_string() |> String.replace(~r/\B(?=(\d{3})+(?!\d))/, ",")

  defp number(_missing), do: "0"

  # Recorded cost only; a channel without a price is "Cost not recorded", never $0.
  defp money(cost) do
    precision =
      if Decimal.compare(cost, Decimal.new(0)) == :gt and
           Decimal.compare(cost, Decimal.new("0.01")) == :lt,
         do: 4,
         else: 2

    "$" <> Decimal.to_string(Decimal.round(cost, precision), :normal)
  end

  defp encode(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
