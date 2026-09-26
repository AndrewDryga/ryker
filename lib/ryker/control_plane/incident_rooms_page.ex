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
  words people use; references wait in one closed Details disclosure.
  """
  use Phoenix.Component

  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Components, Kit, ShortTime, SlackNames, UsageProjection}

  @statuses ~w(requested ready blocked closed)

  @doc "The one sentence under the list's title."
  @spec description() :: String.t()
  def description, do: "Slack channels Ryker opens to work on an incident with your team."

  @doc "The one sentence under a room's title: where the room stands, in words."
  @spec summary(map()) :: String.t()
  def summary(%{status: :requested}),
    do: "Ryker is creating this Slack room and inviting the responders."

  # An open room whose channel is gone for now says that first: the channel
  # is where Ryker's work in the room happens.
  def summary(%{status: :ready, channel_state: :archived}),
    do: "The room's channel is archived in Slack, so Ryker's work in it is paused."

  def summary(%{status: :ready, channel_state: :unavailable}),
    do: "Ryker cannot reach the room's channel in Slack, so its work in it is paused."

  def summary(%{status: :ready, channel_state: :deleted}),
    do: "Slack deleted the room's channel, so Ryker is closing the room."

  def summary(%{status: :ready}),
    do: "The room is open in Slack. Ryker works on the incident there with your team."

  def summary(%{status: :blocked}),
    do: "Setting up this Slack room stopped before it finished, and it needs a person."

  def summary(%{status: :closed}), do: "The room is closed."
  def summary(_room), do: "A Slack room Ryker opened for an incident."

  @doc "The list body: its counts, the toolbar, one row per room, and what would put one here."
  @spec list([map()], map(), DateTime.t() | nil) :: iodata()
  def list(items, params, now \\ nil) do
    params = UsageProjection.link_params(params)
    query = String.slice(params["q"] || "", 0, 200)
    status = if params["status"] in @statuses, do: params["status"], else: ""

    %{
      __changed__: nil,
      items: items,
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
      <Kit.counts label="Incident rooms" items={counts(@items, @query, @status)} />
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
          id={"room-" <> dom_id(room.ref)}
          name={room.title}
          href={room_path(room.ref)}
          link_row
          icon={:incident}
          icon_tone={if room.status in [:ready, :requested, :blocked], do: :warn, else: :off}
          group={group}
          state={state(room.status)}
          at={Kit.clock(room[:requested_at])}
          at_time={room[:requested_at]}
          meta={row_facts(room)}
        />
      </Kit.entity_list>
      <Kit.empty
        :if={@items == [] and @filtered}
        title="No incident rooms match"
        text="Try other words or another status, or clear the filters."
      />
      <Kit.empty
        :if={@items == [] and not @filtered}
        title="No incident rooms yet"
        text="A room opens when someone chooses Create incident room on Ryker’s offer in an alert’s Slack thread, or when a channel is set to open one for every alert."
      />
    </div>
    """
  end

  @doc """
  A room's own page body: its state, when it opened and its channel on one
  line, its facts two to a line, one card with what Ryker says now, what its
  investigation recorded newest first, any code change it proposed, what
  happened to the room and its channel oldest first, and its references in
  one closed Details.
  """
  @spec detail(map(), DateTime.t() | nil) :: iodata()
  def detail(
        %{room: room, lifecycle: lifecycle, records: records, publication: publication},
        now \\ nil
      ) do
    records = Enum.filter(records, &is_binary(&1.label))
    progress = records |> Enum.filter(&(&1.kind == "progress")) |> List.last()
    history = history(room, lifecycle)

    %{
      __changed__: nil,
      room: room,
      latest: latest(room, progress),
      records: Enum.reverse(records),
      publication: publication,
      history: history,
      last_change: last_change(history, records, publication),
      now: now || DateTime.utc_now()
    }
    |> detail_view()
    |> Safe.to_iodata()
  end

  defp detail_view(assigns) do
    ~H"""
    <div class="incident-room-view">
      <Kit.status_line id="incident-room-status" state={state(@room.status)}>
        <.moment :if={@room.requested_at} at={@room.requested_at} now={@now} prefix="opened " />
        <a :if={@room.channel_ref} href={channel_path(@room.workspace_ref, @room.channel_ref)}>
          {channel(@room)}
        </a>
        <a :if={@room.status == :blocked} href={failure_path(@room.ref)} data-tone="warn">
          See what stopped
        </a>
      </Kit.status_line>
      <Kit.facts
        id="incident-room-facts"
        class="incident-room-facts"
        facts={room_facts(@room, @last_change, @now)}
      />
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
          <Kit.empty title="No update yet" text={no_update(@room)} />
        <% end %>
      </section>
      <section id="investigation" aria-labelledby="investigation-title">
        <Kit.section_head
          id="investigation-title"
          title="Investigation"
          lede="What Ryker recorded while it worked on the incident, newest first. The timeline has every step."
        >
          <:actions :if={@room.episode_ref}>
            <a href={timeline_path(@room.episode_ref)}>Open the timeline</a>
          </:actions>
        </Kit.section_head>
        <Kit.entity_list
          :if={@records != []}
          label="What Ryker recorded"
          class="incident-room-records"
        >
          <.record_row
            :for={{record, group} <- Enum.zip(@records, Kit.day_groups(@records, & &1[:at], @now))}
            record={record}
            group={group}
          />
        </Kit.entity_list>
        <Kit.empty
          :if={@records == [] and is_nil(@room.episode_ref)}
          title="The investigation has not started"
          text="It starts in the room once the channel is ready and the responders are invited."
        />
        <Kit.empty
          :if={@records == [] and is_binary(@room.episode_ref)}
          title="Nothing recorded yet"
          text="Evidence, findings and progress appear here as Ryker records them."
        />
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
      <section id="room-history" aria-labelledby="room-history-title">
        <Kit.section_head
          id="room-history-title"
          title="Room history"
          lede="What happened to the room and its Slack channel, oldest first."
        />
        <Kit.entity_list label="Room history">
          <Kit.entity_row
            :for={
              {{event, group}, index} <-
                @history |> Enum.zip(Kit.day_groups(@history, & &1.at, @now)) |> Enum.with_index()
            }
            id={"room-event-#{index}"}
            icon={event.icon}
            name={event.name}
            meta={event.meta}
            group={group}
            at={Kit.clock(event.at)}
            at_time={event.at}
          />
        </Kit.entity_list>
      </section>
      <Components.disclosure id="incident-room-details" label="Details" class="incident-room-details">
        <Kit.facts facts={support_facts(@room, @publication)} />
      </Components.disclosure>
    </div>
    """
  end

  attr(:record, :map, required: true)
  attr(:group, :string, default: nil)

  # One thing Ryker recorded: a tile for its kind, its title and what it says,
  # the kind as the word at the edge beside the clock. Words longer than about
  # three lines show three and open in place.
  defp record_row(assigns) do
    assigns = assign(assigns, :long, long?(assigns.record.summary))

    ~H"""
    <Kit.entity_row
      id={"record-" <> dom_id(@record.ref)}
      class={["incident-room-record", @long && "incident-room-long"]}
      icon={record_icon(@record.kind)}
      name={record_name(@record)}
      text={@record.summary}
      state={{:off, @record.label}}
      group={@group}
      at={Kit.clock(@record[:at])}
      at_time={@record[:at]}
    >
      <:details :if={@long}>
        <details class="incident-room-more">
          <summary phx-no-format><span class="incident-room-show">Show more</span><span class="incident-room-less">Show less</span></summary>
        </details>
      </:details>
    </Kit.entity_row>
    """
  end

  attr(:at, :any, required: true)
  attr(:now, :any, required: true)
  attr(:prefix, :string, default: nil)
  attr(:capital, :boolean, default: false)

  # A time the way a person says it, "opened yesterday at 08:01", with the
  # exact UTC instant a pointer away.
  defp moment(assigns) do
    ~H"""
    <time datetime={iso(@at)} title={ShortTime.full(utc(@at))}>{@prefix}{spoken(@at, @now, @capital)}</time>
    """
  end

  @doc "A room's state as a dot and a word."
  @spec state(atom() | String.t()) :: {atom(), String.t()}
  def state(status) when is_binary(status) and status in @statuses,
    do: state(String.to_existing_atom(status))

  def state(:requested), do: {:busy, "Setting up"}
  def state(:ready), do: {:on, "Open"}
  def state(:blocked), do: {:warn, "Needs attention"}
  def state(:closed), do: {:off, "Closed"}
  def state(_unknown), do: {:off, "Unknown"}

  # Where the room is, what it is about, and what came of it; when it opened
  # is the row's edge and its day's heading.
  defp row_facts(room) do
    [
      channel_fact(room),
      room.repository_ref,
      room.episode_ref && anchor(%{href: timeline_path(room.episode_ref), text: "investigation"}),
      publication_words(room.publication_status)
    ]
  end

  defp channel_fact(%{channel_ref: nil}), do: "channel not created yet"
  defp channel_fact(room), do: {:strong, channel(room)}

  # A room's facts, read two to a line: its channel and who can join it, where
  # it came from and where its work runs, when it opened and last changed.
  defp room_facts(room, last_change, now) do
    [
      {"Channel", room_channel(room)},
      {"Who can join",
       if(room.private, do: "Only people who are invited", else: "Anyone in the workspace")},
      {"Opened from", source(room)},
      works_in(room),
      {"Opened", fact_time(room.requested_at, now)},
      {"Last change", fact_time(last_change, now)}
    ]
  end

  # Where the investigation works: the environment the room was opened in and
  # the repository its code changes go to, or only that repository for a room
  # opened outside any environment.
  defp works_in(%{environment_name: name} = room) when is_binary(name),
    do: {"Environment", name <> " · " <> repository(room)}

  defp works_in(room), do: {"Repository", repository(room)}

  defp repository(room), do: room[:repository_name] || room.repository_ref

  defp room_channel(%{channel_ref: nil}), do: "Not created yet"

  defp room_channel(room) do
    %{
      __changed__: nil,
      href: channel_path(room.workspace_ref, room.channel_ref),
      text: channel(room),
      state: channel_state(room.channel_state)
    }
    |> channel_link()
  end

  defp channel_link(assigns),
    do: ~H|<a href={@href}>{@text}</a>{if @state, do: " · " <> @state}|

  # A channel Slack has not named for Ryker yet keeps the name Ryker gave it.
  defp channel(room) do
    name = SlackNames.name(room.workspace_ref, room.channel_ref)

    cond do
      SlackNames.named?("slack:#{room.workspace_ref}:#{room.channel_ref}") -> name
      is_binary(room[:channel_name]) and room[:channel_name] != "" -> "#" <> room.channel_name
      true -> name
    end
  end

  # The alert thread the room was opened from, by its channel's name once
  # Slack has named it and never by the channel's ID, leading to that
  # request's timeline.
  defp source(%{source_channel_ref: nil}), do: nil

  defp source(room) do
    text =
      if SlackNames.named?("slack:#{room.workspace_ref}:#{room.source_channel_ref}"),
        do:
          "The alert thread in " <> SlackNames.name(room.workspace_ref, room.source_channel_ref),
        else: "The alert thread"

    case room[:source_episode_ref] do
      ref when is_binary(ref) -> anchor(%{href: timeline_path(ref), text: text})
      _none -> text
    end
  end

  # An open channel needs no word beside its name; one that is not is said.
  defp channel_state(:archived), do: "archived"
  defp channel_state(:deleted), do: "deleted"
  defp channel_state(:unavailable), do: "Ryker cannot reach it"
  defp channel_state(_active_or_pending), do: nil

  # What Ryker says now: its latest progress, the stage as the word, lit while
  # its investigation is working. A closed room, or one whose channel is gone
  # for now, says that first and where Ryker's words went.
  defp latest(%{status: :closed} = room, progress),
    do: card({:off, "Closed"}, progress, room[:closed_note] || "The room is closed.")

  defp latest(%{status: :ready, channel_state: :archived}, progress),
    do:
      card(
        {:off, "Paused"},
        progress,
        "The channel is archived, so Ryker paused the investigation; its reply waits until someone restores the channel in Slack."
      )

  defp latest(%{status: :ready, channel_state: :unavailable}, progress),
    do:
      card(
        {:off, "Paused"},
        progress,
        "Ryker cannot reach the channel, so it paused the investigation; its reply waits until Ryker can post there again."
      )

  defp latest(%{status: :ready, channel_state: :deleted}, progress),
    do:
      card(
        {:busy, "Closing"},
        progress,
        "Slack deleted the channel, so Ryker is closing the room."
      )

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

  # The room's milestones in the order they happen, what Slack reported about
  # its channel, and its closing, oldest first. A channel whose state changed
  # since it was created no longer knows when that was: it keeps its place
  # after the request, without a time.
  defp history(room, lifecycle) do
    [
      %{name: "Room requested", icon: :bell, at: room.requested_at},
      room.channel_ref && %{name: "Channel created", icon: :hash, at: room[:channel_created_at]},
      room[:invited_at] &&
        %{name: "People invited", icon: :chat, at: room.invited_at, meta: [invited(room)]},
      room[:ready_at] && %{name: "Room ready", icon: :check, at: room.ready_at},
      room[:stopped_at] && %{name: "Setup stopped", icon: :incident, at: room.stopped_at}
    ]
    |> Enum.concat(
      Enum.map(
        lifecycle,
        &%{name: event_words(&1.kind), icon: event_icon(&1.kind), at: &1.occurred_at}
      )
    )
    |> Enum.concat([room[:closed_at] && %{name: "Room closed", icon: :close, at: room.closed_at}])
    |> Enum.filter(& &1)
    |> Enum.map(&Map.put_new(&1, :meta, []))
    |> oldest_first()
  end

  # A step without a time sorts at the time of the step before it.
  defp oldest_first(events) do
    events
    |> Enum.map_reduce(nil, fn event, previous ->
      at = event.at || previous
      {{at, event}, at}
    end)
    |> elem(0)
    |> Enum.sort_by(fn {at, _event} -> at && DateTime.to_unix(utc(at), :microsecond) end)
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
  defp event_words(:observed_unavailable), do: "Ryker could not reach the channel"
  defp event_words(kind), do: words(to_string(kind))

  defp event_icon(:joined), do: :arrow
  defp event_icon(:archived), do: :arrow_down
  defp event_icon(:unarchived), do: :arrow_up
  defp event_icon(kind) when kind in [:left, :deleted], do: :close
  defp event_icon(:observed_unavailable), do: :incident
  defp event_icon(_observed), do: :search

  # The newest thing the page shows: a record, a step of the room, or its
  # code change. The room's own row changes with every check of its channel,
  # which is not a change anyone reading the page would recognise.
  defp last_change(history, records, publication) do
    [publication && publication.updated_at | Enum.map(history, & &1.at)]
    |> Enum.concat(Enum.map(records, & &1[:at]))
    |> Enum.filter(& &1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp support_facts(room, publication) do
    [
      {"Room ID", code(room.ref)},
      {"Slack workspace ID", code(room.workspace_ref)},
      {"Channel ID", code(room.channel_ref)},
      {"Opened from channel ID", code(room[:source_channel_ref])},
      {"Offer record ID", code(room[:record_ref])},
      {"Investigation request ID", code(room.episode_ref)},
      {"Opened from request ID",
       code(if room[:source_episode_ref] != room.episode_ref, do: room[:source_episode_ref])},
      {"Environment ID", code(room[:environment_ref])},
      {"Code change ID", code(publication && publication.ref)},
      {"Commit", code(publication && publication.commit_sha)},
      {"Code change problem",
       code(publication && publication.status == :blocked && publication.last_error)}
    ]
  end

  defp code(value) when value in [nil, false], do: nil
  defp code(value), do: code_tag(%{__changed__: nil, value: value})
  defp code_tag(assigns), do: ~H|<code>{@value}</code>|

  defp fact_time(nil, _now), do: nil

  defp fact_time(at, now),
    do: moment(%{__changed__: nil, at: at, now: now, prefix: nil, capital: true})

  # "yesterday at 08:01": the day the way a day heading names it, then the
  # clock; in a sentence today and yesterday are lower case.
  defp spoken(at, now, capital) do
    at = utc(at)
    day = Kit.day_label(DateTime.to_date(at), DateTime.to_date(now))
    if(capital, do: day, else: in_sentence(day)) <> " at " <> Kit.clock(at)
  end

  defp in_sentence("Today"), do: "today"
  defp in_sentence("Yesterday"), do: "yesterday"
  defp in_sentence(day), do: day

  defp iso(at), do: at |> utc() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp utc(%DateTime{} = at), do: DateTime.shift_zone!(at, "Etc/UTC")
  defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")

  defp words(value) when is_binary(value),
    do: value |> String.replace("_", " ") |> String.capitalize()

  defp words(_value), do: nil

  # The list leads with how many rooms it holds, then how many of them are
  # open, which opens the Open view. Both count the rooms listed, so a status
  # view says only how many match (its open count would be all of them or
  # none), and a search's open count keeps the search.
  defp counts(items, query, "" = _status) do
    [
      Kit.list_total(length(items), {"room", "rooms"}, query != ""),
      %{
        value: Enum.count(items, &(&1.status == :ready)),
        label: "open",
        href: "/incident-rooms?" <> URI.encode_query(open_view(query))
      }
    ]
  end

  defp counts(items, _query, _status),
    do: [Kit.list_total(length(items), {"room", "rooms"}, true)]

  defp open_view(""), do: [status: "ready"]
  defp open_view(query), do: [q: query, status: "ready"]

  defp anchor(assigns), do: ~H|<a href={@href}>{@text}</a>|

  defp room_path(ref), do: "/incident-rooms/" <> segment(ref)
  defp timeline_path(ref), do: "/timeline/" <> segment(ref)
  defp failure_path(ref), do: "/failures/slack_incident/" <> segment(ref)

  defp channel_path(workspace, channel),
    do: "/channels/" <> segment(workspace) <> "/" <> segment(channel)

  defp dom_id(ref), do: String.replace(to_string(ref), ~r/[^A-Za-z0-9_-]/, "-")
  defp segment(value), do: value |> to_string() |> URI.encode(&URI.char_unreserved?/1)
end
