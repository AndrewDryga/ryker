defmodule Ryker.ControlPlane.IncidentRoomsPage do
  @moduledoc """
  Incident rooms (`/incident-rooms`): the Slack channels Ryker opens to work
  on an incident with people, as Kit rows under one toolbar, and one room's
  own page, in the order a person opening it during an incident needs it:
  where the room stands, what Ryker says now, what it found, any code change
  it proposed, and what happened to the room and its channel.

  A room is created only from Ryker's incident offer in Slack (someone
  chooses "Create incident room", or a channel opens one for every alert), so
  the list says how to ask instead of offering a create button. States are
  words people use; references wait in one closed Details disclosure. An
  open list redraws when a room or its code change does (`subscriptions/0`);
  a room's own page listens to that room (`IncidentProjection.subscriptions/1`).
  """
  use Phoenix.Component
  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{ChannelsPage, Components, Kit, Paths, ShortTime, SlackMarkdown, Units}
  alias Ryker.ControlPlane.Search
  alias Ryker.ControlPlane.UsageProjection
  alias Ryker.ConversationRef
  alias Ryker.Publication
  alias Ryker.Slack
  alias Ryker.UTCDateTime
  alias Ryker.Wording

  @doc """
  The topics an open list of rooms listens to, as the context functions that
  subscribe to them (`Ryker.ControlPlane.WorkbenchLive`): every room, and the
  code changes the list shows beside each.
  """
  def subscriptions do
    [
      {Slack.IncidentRooms, :subscribe_rooms, []},
      {Publication.Custody, :subscribe_publications, []}
    ]
  end

  @statuses ~w(requested ready blocked closed)

  @doc "The one sentence under the list's title."
  @spec description() :: String.t()
  def description, do: "Slack channels Ryker opens to work on an incident with your team."

  @doc """
  The sentence under a room's title, when the room needs one: what is wrong
  and what to do, or what is happening to it. An open room says nothing
  there, and neither does a closed one: the status line already says so, and
  Now says where Ryker stands. The channel's name is the status line's alone.
  """
  @spec summary(map()) :: String.t() | nil
  def summary(%{closing: true}),
    do: "Closing: Ryker is stopping its work here and saying so in Slack."

  def summary(%{status: :requested}),
    do: "Ryker is creating this Slack room and inviting the responders."

  # An open room whose channel Ryker cannot use says so first, and what to do
  # about it: the channel is where Ryker's work in the room happens. Andrew,
  # 2026-10-03, of "Ryker cannot reach the room's channel in Slack, so its work
  # in it is paused.": "wtf?"
  def summary(%{status: :ready, channel_state: :archived}) do
    "The room's channel is archived in Slack, so Ryker stopped working in it. " <>
      "Restore the channel in Slack to carry on, or close the room."
  end

  def summary(%{status: :ready, channel_state: :unavailable}) do
    "Ryker can't find the room's channel in Slack: it is gone, or Ryker is no longer in it. " <>
      "Add Ryker to the channel again, or close the room."
  end

  def summary(%{status: :ready, channel_state: :deleted}),
    do: "Slack deleted the room's channel, so Ryker is closing the room."

  def summary(%{status: :blocked}),
    do: "Setting up this Slack room stopped before it finished. Retry it, or close the room."

  def summary(_open_or_closed), do: nil

  @doc """
  Close, opposite a room's title, while the room is open, being set up or
  stuck. It asks first, saying what closing does (`close_explanation/1`).
  """
  @spec actions(map()) :: String.t() | nil
  def actions(%{status: status} = room) when status in [:requested, :ready, :blocked] do
    if room[:closing] do
      nil
    else
      %{__changed__: nil, room: room}
      |> close_control()
      |> Safe.to_iodata()
      |> IO.iodata_to_binary()
    end
  end

  def actions(_room), do: nil

  defp close_control(assigns) do
    ~H"""
    <Components.action_button
      path={Paths.action("slack_incident", @room.ref, "close")}
      label="Close room"
    />
    """
  end

  @doc "What closing a room does, in the words its Close question uses."
  @spec close_explanation(map()) :: String.t()
  def close_explanation(%{channel_ref: nil}) do
    "Ryker stops setting up the room and says so in the alert thread it came from. " <>
      "You can't reopen it."
  end

  def close_explanation(room) do
    said =
      if room.status == :ready and room.channel_state == :active,
        do: "posts a closing note in #{channel(room)} and in the alert thread it came from",
        else: "says so in the alert thread it came from"

    "Ryker stops investigating, #{said}, and won't answer in the channel again. " <>
      "The channel stays in Slack; archive it there when you no longer need it. " <>
      "The room's history stays here, and you can't reopen it."
  end

  # A room's state as a dot and a word; one a person asked to close says so.
  @spec room_state(map()) :: {atom(), String.t()}
  defp room_state(%{closing: true}), do: {:busy, "Closing"}
  defp room_state(room), do: state(room.status)

  @doc """
  The list body for one page of rooms (`IncidentProjection.list/1`): its
  counts, the toolbar, one row per room, the pager, and what would put one
  here.
  """
  @spec list(map(), map(), DateTime.t() | nil) :: iodata()
  def list(rooms, params, now \\ nil) do
    params = UsageProjection.link_params(params)
    query = Search.term(params["q"]) || ""
    status = if params["status"] in @statuses, do: params["status"], else: ""

    %{
      __changed__: nil,
      rooms: rooms,
      items: rooms.items,
      query: query,
      status: status,
      filtered: query != "" or status != "",
      now: now || DateTime.utc_now()
    }
    |> list_view()
    |> Safe.to_iodata()
  end

  defp list_view(assigns) do
    ~H"""
    <div class="incident-rooms-view">
      <Kit.counts label="Incident rooms" items={counts(@rooms, @query, @status)} />
      <Kit.toolbar>
        <Components.filter_toolbar
          id="operator-search"
          path="/incident-rooms"
          label="Search incident rooms"
          placeholder="Search incident rooms"
          query={@query}
          filtered={@filtered}
          disabled={@items == [] and not @filtered}
          selects={[
            %{
              id: "incident-status",
              name: "status",
              label: "Status",
              value: @status,
              options: [
                {"", "All rooms"},
                {"requested", "Setting up"},
                {"ready", "Open"},
                {"blocked", "Needs attention"},
                {"closed", "Closed"}
              ]
            }
          ]}
        />
      </Kit.toolbar>
      <Kit.entity_list :if={@items != []} label="Incident rooms">
        <Kit.entity_row
          :for={{room, group} <- Enum.zip(@items, Kit.day_groups(@items, & &1[:requested_at], @now))}
          id={"room-" <> Kit.dom_id(room.ref)}
          name={room.title}
          href={Paths.incident_room(room.ref)}
          link_row
          icon={:incident}
          icon_tone={if room.status in [:ready, :requested, :blocked], do: :warn, else: :off}
          group={group}
          state={room_state(room)}
          at={Kit.clock(room[:requested_at])}
          at_time={room[:requested_at]}
          meta={row_facts(room)}
        />
      </Kit.entity_list>
      <Components.pager
        page={@rooms.page}
        pages={@rooms.pages}
        path={&Paths.query("/incident-rooms", q: @query, status: @status, page: &1)}
        label="Incident room pages"
        earlier="Newer"
        later="Older"
      />
      <Kit.empty
        :if={@items == [] and @filtered}
        icon={:search}
        title="No incident rooms match"
        text="Try other words or another status, or clear the filters."
      />
      <Kit.empty
        :if={@items == [] and not @filtered}
        icon={:incident}
        title="No incident rooms yet"
        text="A room opens when someone chooses Create incident room on Ryker's offer in an alert's Slack thread, or when a channel is set to open one for every alert."
      />
    </div>
    """
  end

  @doc """
  A room's own page, read as an incident report: its state, when it opened
  and its channel on one line, then where Ryker stands now, its numbers (how
  long it has been open, when Ryker first found something, how much was said,
  what it cost), who can join and where it came from, the whole story oldest
  first (the alert, the room's steps, what was said and found), any code
  change, and the people. Each thing is said once, and nothing is a
  reference.

  Andrew, 2026-10-03, of the room page before this: "that page is not helpful
  overall, it should be like an incident report page with timeline, what
  happened, etc", and of the next one: "there is so much duplicate
  information here, like channel link for example. details on bottom are
  useless. "Now" is in middle of other elements not placed logically".
  """
  @spec detail(map(), DateTime.t() | nil) :: iodata()
  def detail(%{room: room, lifecycle: lifecycle, records: records} = snapshot, now \\ nil) do
    now = now || DateTime.utc_now()
    records = Enum.filter(records, &is_binary(&1.label))
    progress = records |> Enum.filter(&(&1.kind == "progress")) |> List.last()
    alert = snapshot[:alert]
    conversation = snapshot[:conversation] || []

    %{
      __changed__: nil,
      room: room,
      latest: latest(room, progress),
      publication: snapshot[:publication],
      timeline: timeline(room, alert, conversation, records, lifecycle),
      numbers: numbers(room, records, conversation, snapshot[:accounting], now),
      people: people(room, conversation),
      now: now
    }
    |> detail_view()
    |> Safe.to_iodata()
  end

  defp detail_view(assigns) do
    ~H"""
    <div class="incident-room-view incident-report">
      <Kit.status_line id="incident-room-status" state={room_state(@room)}>
        <.moment :if={@room.requested_at} at={@room.requested_at} now={@now} prefix="opened " />
        <a :if={@room.channel_ref} href={Paths.channel(@room.workspace_ref, @room.channel_ref)}>
          {channel(@room)}
        </a>
        <a
          :if={@room.status == :blocked}
          href={Paths.failure("slack_incident", @room.ref)}
          data-tone="warn"
        >
          See what stopped
        </a>
      </Kit.status_line>
      <section id="now" class="incident-room-now" aria-labelledby="now-title">
        <h2 id="now-title" class="incident-room-now-title">Now</h2>
        <%= if @latest do %>
          <p class="incident-room-now-state">
            <Kit.state tone={elem(@latest.state, 0)} word={elem(@latest.state, 1)} />
            <.moment :if={@latest.at} at={@latest.at} now={@now} prefix="updated " />
          </p>
          <p :if={@latest.text} class="incident-room-now-text">{@latest.text}</p>
          <p :if={@latest.note} class="incident-room-now-note">{@latest.note}</p>
        <% else %>
          <Kit.empty variant={:bare} icon={:chat} title="No update yet" text={no_update(@room)} />
        <% end %>
      </section>
      <section class="episode-metrics incident-room-numbers" aria-label="The incident in numbers">
        <div class="metric-group metric-group-timing">
          <p class="metric-group-label">Timing</p>
          <dl class="metric-group-items">
            <div class="metric">
              <dt>{@numbers.span_label}</dt>
              <dd>{@numbers.span}</dd>
            </div>
            <div class="metric">
              <dt>First finding</dt>
              <dd>{@numbers.first_finding}</dd>
            </div>
          </dl>
        </div>
        <div class="metric-group metric-group-conversation">
          <p class="metric-group-label">In the room</p>
          <dl class="metric-group-items">
            <div class="metric">
              <dt>Messages</dt>
              <dd>{@numbers.messages}</dd>
            </div>
            <div class="metric">
              <dt>Findings</dt>
              <dd>{@numbers.findings}</dd>
            </div>
          </dl>
        </div>
        <div class="metric-group metric-group-cost">
          <p class="metric-group-label">Cost</p>
          <dl class="metric-group-items">
            <div class="metric">
              <dt>Investigation</dt>
              <dd>{@numbers.cost}</dd>
            </div>
          </dl>
        </div>
      </section>
      <Kit.facts id="incident-room-facts" class="incident-room-facts" facts={room_facts(@room)} />
      <section id="timeline" aria-labelledby="timeline-title">
        <Kit.section_head
          id="timeline-title"
          title="Timeline"
          lede="Everything that happened, oldest first."
        >
          <:actions :if={@room.episode_id}>
            <a href={Paths.request(@room.episode_id)}>Every step of the investigation</a>
          </:actions>
        </Kit.section_head>
        <Kit.entity_list label="Timeline" class="incident-room-timeline">
          <.story_row
            :for={{entry, group} <- Enum.zip(@timeline, Kit.day_groups(@timeline, & &1.at, @now))}
            entry={entry}
            group={group}
            now={@now}
          />
        </Kit.entity_list>
      </section>
      <section :if={@publication} id="code-change" aria-labelledby="code-change-title">
        <Kit.section_head
          id="code-change-title"
          title="Code change"
          lede="The change Ryker proposed from the investigation."
        />
        <Kit.entity_list label="Code change">
          <Kit.entity_row
            id="code-change-row"
            icon={:code}
            name={change_name(@publication)}
            href={change_url(@publication)}
            state={change_state(@publication.status)}
            meta={[@publication.repository, @publication.branch_ref]}
            at={ShortTime.text(@publication.updated_at, @now)}
            at_time={@publication.updated_at}
          />
        </Kit.entity_list>
      </section>
      <section :if={@people != []} id="people" aria-labelledby="people-title">
        <Kit.section_head id="people-title" title="People" />
        <Kit.facts id="incident-room-people" facts={@people} />
      </section>
    </div>
    """
  end

  attr(:entry, :map, required: true)
  attr(:group, :string, default: nil)
  attr(:now, :any, required: true)

  # One thing that happened: who or what, what it says, the kind of thing at
  # the edge beside the clock. Words longer than about three lines show three
  # and open in place.
  defp story_row(assigns) do
    assigns =
      assign(assigns,
        long: long?(assigns.entry[:text]),
        words: words(assigns.entry[:text], assigns.entry[:workspace])
      )

    ~H"""
    <Kit.entity_row
      id={"story-" <> @entry.id}
      class={["incident-room-story", @long && "incident-room-long"]}
      icon={@entry.icon}
      icon_tone={@entry[:tone] || :off}
      name={@entry.name}
      text={@words}
      meta={@entry[:meta] || []}
      state={@entry[:state]}
      group={@group}
      at={Kit.clock(@entry.at)}
      at_time={@entry.at}
    >
      <:details :if={@long}>
        <details class="incident-room-more">
          <summary phx-no-format><span class="incident-room-show">Show more</span><span class="incident-room-less">Show less</span></summary>
        </details>
      </:details>
    </Kit.entity_row>
    """
  end

  # -- The story ---------------------------------------------------------------

  # Everything that happened, oldest first: the alert, the room's steps, what
  # people and Ryker said in it, what Ryker recorded, what Slack reported
  # about the channel, and how the room closed. A step without a time keeps
  # its place after the step before it.
  defp timeline(room, alert, conversation, records, lifecycle) do
    said = Enum.map(conversation, &message_entry/1)
    recorded = Enum.map(records, &record_entry/1)
    reported = Enum.with_index(lifecycle, &lifecycle_entry/2)

    [
      alert && alert_entry(alert),
      %{
        id: "requested",
        at: room.requested_at,
        icon: :incident,
        name: "Room requested",
        meta: [requested_words(room)]
      },
      room.channel_ref &&
        %{id: "channel", at: room[:channel_created_at], icon: :hash, name: "Channel created"},
      room[:invited_at] &&
        %{
          id: "invited",
          at: room.invited_at,
          icon: :chat,
          name: "People invited",
          meta: [invited(room)]
        },
      room[:ready_at] &&
        %{
          id: "ready",
          at: room.ready_at,
          icon: :check,
          name: "Room ready",
          meta: ["Ryker started investigating"]
        },
      room[:stopped_at] &&
        %{id: "stopped", at: room.stopped_at, icon: :incident, name: "Setup stopped", tone: :warn}
    ]
    |> Enum.concat(said)
    |> Enum.concat(recorded)
    |> Enum.concat(reported)
    |> Enum.concat([
      room[:closing] &&
        %{
          id: "closing",
          at: room[:close_requested_at],
          icon: :close,
          name: "Close requested",
          meta: ["Ryker is stopping its work here and saying so in Slack"]
        },
      room[:closed_at] &&
        %{
          id: "closed",
          at: room.closed_at,
          icon: :close,
          name: "Room closed",
          text: room[:closed_note]
        }
    ])
    |> Enum.filter(& &1)
    |> oldest_first()
  end

  # The message the room was opened from: an alert an app posted, or what a
  # person asked.
  defp alert_entry(alert) do
    %{
      id: "alert",
      at: alert.at,
      icon: :bell,
      tone: :warn,
      name: who(alert.from),
      text: alert.text || "The message is no longer kept.",
      workspace: alert.workspace,
      meta: [alert.place],
      state: {:off, if(alert.from == :app, do: "Alert", else: "Message")}
    }
  end

  defp message_entry(%{from: :ryker} = message) do
    %{
      id: "reply-" <> message.id,
      at: message.at,
      icon: :chat,
      tone: :accent,
      name: "Ryker",
      text: message.text || "The reply is no longer kept.",
      state: {:off, "Reply"}
    }
  end

  defp message_entry(message) do
    %{
      id: "message-" <> message.id,
      at: message.at,
      icon: :chat,
      name: who(message.from),
      text: message.text || "The message is no longer kept.",
      workspace: message.workspace,
      state: {:off, "Message"}
    }
  end

  defp record_entry(record) do
    %{
      id: "record-" <> Kit.dom_id(record.ref),
      at: record[:at],
      icon: record_icon(record.kind),
      tone: if(record.kind == "finding", do: :info, else: :off),
      name: record_name(record),
      text: record.summary,
      state: {:off, record.label}
    }
  end

  defp lifecycle_entry(event, index) do
    %{
      id: "channel-#{index}",
      at: event.occurred_at,
      icon: event_icon(event.kind),
      tone: if(event.kind in [:observed_unavailable, :left, :deleted], do: :warn, else: :off),
      name: event_words(event.kind)
    }
  end

  defp who({:person, person}), do: Kit.person(%{__changed__: nil, person: person, class: nil})
  defp who(:you), do: "You"
  defp who(:app), do: "An app"
  defp who(_someone), do: "Someone"

  # Who asked for the room: the person who chose Create incident room, or, for
  # a room the channel opens for every alert, that setting.
  defp requested_words(%{requested_by: ref} = room) when is_binary(ref) do
    if Slack.person_ref?(ref) do
      Kit.person(%{__changed__: nil, person: Slack.person(room.workspace_ref, ref), class: nil})
    else
      "opened for the alert by the channel's setting"
    end
  end

  defp requested_words(_room), do: nil

  # -- The numbers -----------------------------------------------------------------

  defp numbers(room, records, conversation, accounting, now) do
    until = room[:closed_at] || now

    %{
      span_label: if(room.status == :closed, do: "Lasted", else: "Open for"),
      span: if(room.requested_at, do: span(room.requested_at, until), else: "Not opened"),
      first_finding: first_finding(room, records),
      messages: length(conversation),
      findings: Enum.count(records, &(&1.kind in ["finding", "evidence"])),
      cost: cost(accounting)
    }
  end

  # How long after the room opened Ryker first recorded what it found.
  defp first_finding(%{requested_at: nil}, _records), do: "None yet"

  defp first_finding(room, records) do
    case Enum.find(records, &(&1.kind in ["finding", "evidence"] and &1[:at])) do
      nil -> "None yet"
      record -> "after " <> span(room.requested_at, record.at)
    end
  end

  # A span the way a person says it: 40 min, 3 h 5 min, 9 d 4 h.
  defp span(from, to) do
    minutes =
      max(div(DateTime.diff(UTCDateTime.to_utc(to), UTCDateTime.to_utc(from), :second), 60), 0)

    cond do
      minutes < 1 -> "under a minute"
      minutes < 60 -> "#{minutes} min"
      minutes < 1_440 -> hours(div(minutes, 60), rem(minutes, 60))
      true -> days(div(minutes, 1_440), div(rem(minutes, 1_440), 60))
    end
  end

  defp hours(hours, 0), do: "#{hours} h"
  defp hours(hours, minutes), do: "#{hours} h #{minutes} min"
  defp days(days, 0), do: "#{days} d"
  defp days(days, hours), do: "#{days} d #{hours} h"

  # Counted the way the request page counts it, an estimate marked ≈.
  defp cost(%{costed: _} = totals), do: Units.cost(totals)
  defp cost(_no_investigation), do: "None"

  # -- The people ------------------------------------------------------------------

  # Who asked for the room, who it invited, and who wrote in it.
  defp people(room, conversation) do
    invited = Enum.map(room[:invite_user_refs] || [], &Slack.person(room.workspace_ref, &1))
    groups = Enum.map(room[:invite_user_group_refs] || [], &("user group " <> &1))

    wrote =
      for %{from: {:person, person}} <- conversation, uniq: true, do: person

    [
      {"Asked for it", requested_words(room)},
      (invited != [] or groups != []) &&
        {"Invited", Kit.people(%{__changed__: nil, people: invited, more: groups})},
      wrote != [] &&
        {"Wrote in the room", Kit.people(%{__changed__: nil, people: wrote, more: []})}
    ]
    |> Enum.filter(&(is_tuple(&1) and elem(&1, 1) not in [nil, ""]))
  end

  attr(:at, :any, required: true)
  attr(:now, :any, required: true)
  attr(:prefix, :string, default: nil)

  # A time the way a person says it, "opened yesterday at 08:01", with the
  # exact UTC instant a pointer away.
  defp moment(assigns) do
    ~H"""
    <time datetime={ShortTime.iso(@at)} title={UTCDateTime.readable(UTCDateTime.to_utc(@at))}>{@prefix}{spoken(
      @at,
      @now
    )}</time>
    """
  end

  # A room's state as a dot and a word.
  defp state(status) when is_binary(status) and status in @statuses,
    do: state(String.to_existing_atom(status))

  defp state(:requested), do: {:busy, "Setting up"}
  defp state(:ready), do: {:on, "Open"}
  defp state(:blocked), do: {:warn, "Needs attention"}
  defp state(:closed), do: {:off, "Closed"}
  defp state(_unknown), do: {:off, "Unknown"}

  # Where the room is, what it is about, and what came of it; when it opened
  # is the row's edge and its day's heading.
  defp row_facts(room) do
    [
      channel_fact(room),
      repository(room),
      room.episode_id && anchor(%{href: Paths.request(room.episode_id), text: "investigation"}),
      publication_words(room.publication_status)
    ]
  end

  defp channel_fact(%{channel_ref: nil}), do: "channel not created yet"
  defp channel_fact(room), do: {:strong, channel(room)}

  # A room's facts: who can join it, where it came from and where its work
  # runs. Its channel, when it opened and how long it has been open are its
  # status line's and its numbers'.
  defp room_facts(room) do
    [
      {"Who can join",
       if(room.private, do: "Only people who are invited", else: "Anyone in the workspace")},
      {"Opened from", source(room)},
      works_in(room)
    ]
  end

  # Where the investigation works: the environment the room was opened in and
  # the repository its code changes go to, or only that repository for a room
  # opened outside any environment.
  defp works_in(%{environment_name: name} = room) when is_binary(name),
    do: {"Environment", name <> " · " <> repository(room)}

  defp works_in(room), do: {"Repository", repository(room)}

  defp repository(room), do: room[:repository_name] || room.repository_ref

  # A channel Slack has not named for Ryker yet keeps the name Ryker gave it.
  defp channel(room), do: ChannelsPage.channel_name(room.workspace_ref, room.channel_ref, room)

  # The alert thread the room was opened from, by its channel's name once
  # Slack has named it and never by the channel's ID, leading to that
  # request's timeline.
  defp source(%{source_channel_ref: nil}), do: nil

  defp source(room) do
    text =
      if Slack.named_destination?(
           ConversationRef.slack(room.workspace_ref, room.source_channel_ref)
         ),
         do: "The alert thread in " <> Slack.name(room.workspace_ref, room.source_channel_ref),
         else: "The alert thread"

    case room[:source_episode_id] do
      ref when is_binary(ref) -> anchor(%{href: Paths.request(ref), text: text})
      _none -> text
    end
  end

  # What Ryker says now: its latest progress, the stage as the word, lit while
  # its investigation is working. A closed room, or one whose channel is gone
  # for now, says that first and where Ryker's words went.
  defp latest(%{status: :closed} = room, progress),
    do: card({:off, "Closed"}, progress, room[:closed_note] || "The room is closed.")

  # A channel Ryker cannot use pauses the work; the sentence under the title
  # says why and what to do, so Now says only that it is paused.
  defp latest(%{status: :ready, channel_state: state}, progress)
       when state in [:archived, :unavailable],
       do: card({:off, "Paused"}, progress, nil)

  defp latest(%{status: :ready, channel_state: :deleted}, progress),
    do: card({:busy, "Closing"}, progress, nil)

  defp latest(_room, nil), do: nil

  defp latest(room, progress),
    do: card({stage_tone(room[:episode_state]), record_name(progress)}, progress, nil)

  defp card(state, progress, note) do
    %{
      at: progress && progress[:at],
      note: note,
      state: state,
      text: progress && progress.summary
    }
  end

  defp stage_tone(:working), do: :busy
  defp stage_tone(state) when state in [:complete, :cancelled], do: :off
  defp stage_tone(_waiting), do: :on

  defp no_update(%{status: :requested}),
    do: "Ryker starts investigating once the room is set up and the responders are invited."

  defp no_update(%{status: :blocked}),
    do: "Setting up the room stopped before Ryker started investigating."

  defp no_update(_room),
    do: "Ryker posts what it finds in the Slack room, and its latest update appears here."

  defp record_name(%{kind: "progress", title: phase}) when is_binary(phase), do: words(phase)
  defp record_name(%{title: title}) when is_binary(title) and title != "", do: title
  defp record_name(record), do: record.label

  # What kind of thing each record is, as the tile the timeline would draw.
  defp record_icon(kind) when kind in ["evidence", "coverage"], do: :search
  defp record_icon("finding"), do: :incident
  defp record_icon("progress"), do: :activity
  defp record_icon(kind) when kind in ["alert_assessment", "goal", "goal_state"], do: :check
  defp record_icon("input_request"), do: :chat
  defp record_icon("event_wait"), do: :clock
  defp record_icon("emisar_approval"), do: :bolt
  defp record_icon(kind) when kind in ["publication_offer", "task_offer"], do: :code
  defp record_icon(_kind), do: :cards

  # About three lines of a row's words at their widest; a record longer than
  # that shows three and opens in place.
  @long_text 300

  defp long?(text) when is_binary(text),
    do: String.length(text) > @long_text or length(String.split(text, "\n")) > 3

  defp long?(_text), do: false

  # A message's words with their formatting and mentions, HTML-inert, on the
  # lines of its row: a code block reads as inline code, so the row keeps its
  # three lines and its size.
  defp words(nil, _workspace), do: nil
  defp words(text, nil), do: {:safe, text |> inline_code() |> SlackMarkdown.render()}

  defp words(text, workspace),
    do: {:safe, text |> inline_code() |> SlackMarkdown.render(workspace)}

  defp inline_code(text) do
    Regex.replace(~r/```[a-z]*\n?([\s\S]*?)```/u, text, fn _block, code ->
      "`" <> (code |> String.split(~r/\s*\n\s*/u, trim: true) |> Enum.join(" · ")) <> "`"
    end)
  end

  defp change_name(%{pr_number: number}) when is_integer(number), do: "Pull request ##{number}"
  defp change_name(_publication), do: "Proposed change"

  defp change_url(%{pr_url: "https://" <> _ = url}), do: url
  defp change_url(_publication), do: nil

  defp change_state(status) when status in [:review_pending, :review_ready],
    do: {:busy, "Waiting for review"}

  defp change_state(:reviewed), do: {:warn, "Waiting for approval"}

  defp change_state(status) when status in [:publish_pending, :published_ready],
    do: {:busy, "Being published"}

  defp change_state(:published), do: {:on, "Opened"}
  defp change_state(:blocked), do: {:warn, "Needs attention"}
  defp change_state(:discarded), do: {:off, "Discarded"}
  defp change_state(_status), do: {:off, "Proposed"}

  defp publication_words(nil), do: nil

  defp publication_words(status) when status in [:review_pending, :review_ready],
    do: "code change waiting for review"

  defp publication_words(status) when status in [:reviewed, :publish_pending, :published_ready],
    do: "code change being published"

  defp publication_words(:published), do: "pull request opened"
  defp publication_words(:blocked), do: "code change needs attention"
  defp publication_words(:discarded), do: "code change discarded"
  defp publication_words(_status), do: "code change"

  # A step without a time sorts at the time of the step before it.
  defp oldest_first(events) do
    events
    |> Enum.map_reduce(nil, fn event, previous ->
      at = event.at || previous
      {{at, event}, at}
    end)
    |> elem(0)
    |> Enum.sort_by(fn {at, _event} ->
      at && DateTime.to_unix(UTCDateTime.to_utc(at), :microsecond)
    end)
    |> Enum.map(&elem(&1, 1))
  end

  defp invited(room) do
    [
      counted(room[:invited_people] || 0, "person", "people"),
      counted(room[:invited_groups] || 0, "group", "groups")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" and ")
  end

  defp counted(0, _one, _many), do: nil
  defp counted(1, one, _many), do: "1 " <> one
  defp counted(count, _one, many), do: "#{count} " <> many

  defp event_words(:joined), do: "Ryker joined the channel"
  defp event_words(:left), do: "Ryker left the channel"
  defp event_words(:archived), do: "Channel archived"
  defp event_words(:unarchived), do: "Channel restored"
  defp event_words(:deleted), do: "Channel deleted"
  defp event_words(:observed_active), do: "Ryker found the channel active"
  defp event_words(:observed_archived), do: "Ryker found the channel archived"
  defp event_words(:observed_unavailable), do: "Ryker couldn't find the channel in Slack"
  defp event_words(kind), do: words(to_string(kind))

  defp event_icon(:joined), do: :arrow
  defp event_icon(:archived), do: :arrow_down
  defp event_icon(:unarchived), do: :arrow_up
  defp event_icon(kind) when kind in [:left, :deleted], do: :close
  defp event_icon(:observed_unavailable), do: :incident
  defp event_icon(_observed), do: :search

  # "yesterday at 08:01": the day the way a day heading names it, in a
  # sentence's lower case, then the clock.
  defp spoken(at, now) do
    at = UTCDateTime.to_utc(at)

    in_sentence(Kit.day_label(DateTime.to_date(at), DateTime.to_date(now))) <>
      " at " <> Kit.clock(at)
  end

  defp in_sentence("Today"), do: "today"
  defp in_sentence("Yesterday"), do: "yesterday"
  defp in_sentence(day), do: day

  defp words(value) when is_binary(value),
    do: Wording.label(value)

  defp words(_value), do: nil

  # The list leads with how many rooms match, then how many of them are open,
  # which opens the Open view. A status view says only how many match (its
  # open count would be all of them or none), and a search's open count keeps
  # the search. Both count every room, not the page in hand.
  defp counts(rooms, query, "" = _status) do
    [
      Kit.list_total(rooms.total, {"room", "rooms"}, query != ""),
      %{
        value: rooms.open,
        label: "open",
        href: Paths.query("/incident-rooms", open_view(query))
      }
    ]
  end

  defp counts(rooms, _query, _status),
    do: [Kit.list_total(rooms.total, {"room", "rooms"}, true)]

  defp open_view(""), do: [status: "ready"]
  defp open_view(query), do: [q: query, status: "ready"]

  defp anchor(assigns), do: ~H|<a href={@href}>{@text}</a>|
end
