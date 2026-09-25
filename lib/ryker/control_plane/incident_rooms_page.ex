defmodule Ryker.ControlPlane.IncidentRoomsPage do
  @moduledoc """
  Incident rooms (`/incident-rooms`): the Slack channels Ryker opens to work
  on an incident with people, as Kit rows under one toolbar, and one room's
  own page — what is happening, the room, the investigation Ryker runs in it,
  any code change it proposed, and what happened to the channel.

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

  def summary(%{status: :ready}),
    do: "The room is open in Slack. Ryker works on the incident there with your team."

  def summary(%{status: :blocked}),
    do: "Setting up this Slack room stopped before it finished, and it needs a person."

  def summary(%{status: :closed}), do: "The room is closed."
  def summary(_room), do: "A Slack room Ryker opened for an incident."

  @doc "The list body: the toolbar, one row per room, what would put one here, and how to ask."
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
      <Kit.toolbar count={count(length(@items))}>
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
      <Kit.ask_hint
        lead="To open one, ask Ryker in the alert’s Slack thread:"
        example="Open an incident room for this."
        rest="Ryker offers the room and creates it once you confirm."
      />
    </div>
    """
  end

  @doc "A room's own page body."
  @spec detail(map(), DateTime.t() | nil) :: iodata()
  def detail(
        %{room: room, lifecycle: lifecycle, records: records, publication: publication},
        now \\ nil
      ) do
    progress = records |> Enum.filter(&(&1.kind == "progress")) |> List.last()

    %{
      __changed__: nil,
      room: room,
      progress: progress,
      records: Enum.filter(records, &is_binary(&1.label)),
      publication: publication,
      events: events(room, lifecycle),
      now: now || DateTime.utc_now()
    }
    |> detail_view()
    |> Safe.to_iodata()
  end

  defp detail_view(assigns) do
    ~H"""
    <div class="incident-room-view">
      <Kit.status_line state={state(@room.status)}>
        <ShortTime.time at={@room.requested_at} now={@now} prefix="opened " />
        <a :if={@room.status == :blocked} href={failure_path(@room.ref)}>See what stopped</a>
      </Kit.status_line>
      <section id="happening" aria-labelledby="happening-title">
        <Kit.section_head
          id="happening-title"
          title="What’s happening"
          lede="Ryker’s latest update from its investigation in the room."
        />
        <%= if @progress do %>
          <p :if={@progress.summary} class="incident-room-text">{@progress.summary}</p>
          <Kit.facts facts={[{"Stage", words(@progress.title)}]} />
        <% else %>
          <Kit.empty
            title="No update yet"
            text="Ryker posts what it finds in the Slack room, and its latest update appears here."
          />
        <% end %>
      </section>
      <section id="room" aria-labelledby="room-title">
        <Kit.section_head
          id="room-title"
          title="Room"
          lede="The Slack channel where people and Ryker work on the incident."
        />
        <Kit.facts facts={room_facts(@room, @now)} />
      </section>
      <section id="investigation" aria-labelledby="investigation-title">
        <Kit.section_head
          id="investigation-title"
          title="Investigation"
          lede="What Ryker recorded while it worked in the room. The timeline has every step."
        >
          <:actions :if={@room.episode_ref}>
            <a href={timeline_path(@room.episode_ref)}>Open the timeline</a>
          </:actions>
        </Kit.section_head>
        <Kit.entity_list :if={@records != []} label="What Ryker recorded">
          <Kit.entity_row
            :for={record <- @records}
            id={"record-" <> dom_id(record.ref)}
            name={record_name(record)}
            text={record.summary}
            meta={[record.label]}
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
        <Kit.facts facts={publication_facts(@publication, @now)} />
      </section>
      <section id="room-timeline" aria-labelledby="room-timeline-title">
        <Kit.section_head
          id="room-timeline-title"
          title="Timeline of the room"
          lede="What happened to the Slack channel, oldest first."
        />
        <Kit.entity_list label="Timeline of the room">
          <Kit.entity_row
            :for={{event, index} <- Enum.with_index(@events)}
            id={"room-event-#{index}"}
            name={event.name}
            meta={[time(event.at, @now)]}
          />
        </Kit.entity_list>
      </section>
      <Components.disclosure id="incident-room-details" label="Details" class="incident-room-details">
        <Components.fact_list facts={support_facts(@room, @publication)} />
      </Components.disclosure>
    </div>
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

  defp room_facts(room, now) do
    [
      {"Channel", room_channel(room)},
      {"Channel state", channel_state(room.channel_state)},
      {"Who can join",
       if(room.private, do: "Only people who are invited", else: "Anyone in the workspace")},
      {"Opened from", source(room)},
      {"Repository", room.repository_ref},
      {"Opened", time(room.requested_at, now)},
      {"Last change", time(room.updated_at, now)}
    ]
  end

  defp room_channel(%{channel_ref: nil}), do: "Not created yet"

  defp room_channel(room),
    do: anchor(%{href: channel_path(room.workspace_ref, room.channel_ref), text: channel(room)})

  # A channel Slack has not named for Ryker yet keeps the name Ryker gave it.
  defp channel(room) do
    name = SlackNames.name(room.workspace_ref, room.channel_ref)

    cond do
      SlackNames.named?("slack:#{room.workspace_ref}:#{room.channel_ref}") -> name
      is_binary(room[:channel_name]) and room[:channel_name] != "" -> "#" <> room.channel_name
      true -> name
    end
  end

  defp source(%{source_channel_ref: nil}), do: nil

  defp source(room) do
    name = SlackNames.name(room.workspace_ref, room.source_channel_ref)

    case room[:source_episode_ref] do
      ref when is_binary(ref) -> anchor(%{href: timeline_path(ref), text: name})
      _none -> name
    end
  end

  defp channel_state(:pending), do: "Being created"
  defp channel_state(:active), do: "Active"
  defp channel_state(:archived), do: "Archived"
  defp channel_state(:deleted), do: "Deleted"
  defp channel_state(:unavailable), do: "Ryker cannot reach it"
  defp channel_state(_unknown), do: nil

  defp record_name(%{kind: "progress", title: phase}) when is_binary(phase), do: words(phase)
  defp record_name(%{title: title}) when is_binary(title) and title != "", do: title
  defp record_name(record), do: record.label

  defp publication_facts(publication, now) do
    [
      {"State", publication_state(publication.status)},
      {"Pull request", pull_request(publication)},
      {"Repository", publication.repository},
      {"Branch", publication.branch_ref},
      {"Last problem", if(publication.status == :blocked, do: publication.last_error)},
      {"Last change", time(publication.updated_at, now)}
    ]
  end

  defp pull_request(%{pr_url: "https://" <> _ = url, pr_number: number}) when is_integer(number),
    do: anchor(%{href: url, text: "##{number}"})

  defp pull_request(%{pr_number: number}) when is_integer(number), do: "##{number}"
  defp pull_request(_publication), do: nil

  defp publication_state(status) do
    word = publication_words(status)

    %{__changed__: nil, tone: publication_tone(status), word: String.capitalize(word)}
    |> Kit.state()
  end

  defp publication_tone(:blocked), do: :warn
  defp publication_tone(:published), do: :on
  defp publication_tone(:discarded), do: :off
  defp publication_tone(_pending), do: :busy

  defp publication_words(nil), do: nil

  defp publication_words(status) when status in [:review_pending, :review_ready],
    do: "code change waiting for review"

  defp publication_words(status) when status in [:reviewed, :publish_pending, :published_ready],
    do: "code change being published"

  defp publication_words(:published), do: "pull request opened"
  defp publication_words(:blocked), do: "code change needs attention"
  defp publication_words(:discarded), do: "code change discarded"
  defp publication_words(_status), do: "code change"

  # The room's own milestones, then what Slack reported about the channel.
  defp events(room, lifecycle) do
    requested = %{name: "Room requested", at: room.requested_at}
    observed = Enum.map(lifecycle, &%{name: event_words(&1.kind), at: &1.occurred_at})

    Enum.reject([requested | observed], &is_nil(&1.at))
  end

  defp event_words(:joined), do: "Ryker joined the channel"
  defp event_words(:left), do: "Ryker left the channel"
  defp event_words(:archived), do: "The channel was archived"
  defp event_words(:unarchived), do: "The channel was restored"
  defp event_words(:deleted), do: "The channel was deleted"
  defp event_words(:observed_active), do: "Ryker checked the channel: active"
  defp event_words(:observed_archived), do: "Ryker checked the channel: archived"
  defp event_words(:observed_unavailable), do: "Ryker could not reach the channel"
  defp event_words(kind), do: words(to_string(kind))

  defp support_facts(room, publication) do
    [
      %{label: "Room ID", value: room.ref, identifier: true},
      room.workspace_ref && %{label: "Slack workspace ID", value: room.workspace_ref},
      room.channel_ref && %{label: "Channel ID", value: room.channel_ref},
      room[:source_channel_ref] &&
        %{label: "Opened from channel ID", value: room.source_channel_ref},
      room.episode_ref &&
        %{label: "Investigation request ID", value: room.episode_ref, identifier: true},
      room[:source_episode_ref] &&
        %{label: "Opened from request ID", value: room.source_episode_ref, identifier: true},
      publication && %{label: "Code change ID", value: publication.ref, identifier: true},
      publication && publication.commit_sha &&
        %{label: "Commit", value: publication.commit_sha, identifier: true}
    ]
    |> Enum.reject(&(&1 in [nil, false]))
  end

  defp time(nil, _now), do: nil
  defp time(at, now), do: ShortTime.time(%{__changed__: nil, at: at, now: now})

  defp words(value) when is_binary(value),
    do: value |> String.replace("_", " ") |> String.capitalize()

  defp words(_value), do: nil

  defp count(1), do: "1 incident room"
  defp count(count), do: "#{count} incident rooms"

  defp anchor(assigns), do: ~H|<a href={@href}>{@text}</a>|

  defp room_path(ref), do: "/incident-rooms/" <> segment(ref)
  defp timeline_path(ref), do: "/timeline/" <> segment(ref)
  defp failure_path(ref), do: "/failures/slack_incident/" <> segment(ref)

  defp channel_path(workspace, channel),
    do: "/channels/" <> segment(workspace) <> "/" <> segment(channel)

  defp dom_id(ref), do: String.replace(to_string(ref), ~r/[^A-Za-z0-9_-]/, "-")
  defp segment(value), do: value |> to_string() |> URI.encode(&URI.char_unreserved?/1)
end
