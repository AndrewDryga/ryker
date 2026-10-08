defmodule Ryker.ControlPlane.ChannelsPage do
  @moduledoc """
  The Channels list: the Slack channels Ryker is in and how it takes part in
  each one, as Kit rows under one search box and an In use / All choice. The
  whole row opens the channel's page, where everything about it changes.

  The words for participation and for a channel's state live here once, so
  the list, the channel page and anything else that names them agree. An
  open list redraws when a channel, its last activity or Slack's state
  changes (`subscriptions/0`).
  """
  use Phoenix.Component
  alias Phoenix.HTML.Safe
  alias Ryker.ControlPlane.{Components, Integrations, Kit, PagedRelation, Paths, SettingsView}
  alias Ryker.ControlPlane.Search
  alias Ryker.ControlPlane.ShortTime
  alias Ryker.ConversationRef
  alias Ryker.Episodes
  alias Ryker.Slack

  @doc """
  The topics an open Channels list listens to, as the context functions that
  subscribe to them (`Ryker.ControlPlane.WorkbenchLive`): what the Slack line
  above it reads (`SettingsView.subscriptions/0`, which includes the
  channels), the incident rooms it leaves out, and the Slack conversations
  whose last activity each row shows.
  """
  def subscriptions do
    SettingsView.subscriptions() ++
      [
        {Slack.IncidentRooms, :subscribe_rooms, []},
        {Episodes, :subscribe_conversations, ["slack"]}
      ]
  end

  @doc """
  A channel's name: Slack's, or, until Slack has named an incident room's
  channel, the name Ryker gave that channel. The list, the channel's page and
  the room's page all say the same.
  """
  @spec channel_name(String.t(), String.t(), map() | nil) :: String.t()
  def channel_name(workspace, channel, room) do
    given = if is_map(room), do: room[:channel_name]

    if is_binary(given) and given != "" and
         not Slack.named_destination?(ConversationRef.slack(workspace, channel)),
       do: "#" <> given,
       else: Slack.name(workspace, channel)
  end

  @doc "The search phrase, which channels to show and the page, from the page's query."
  @spec view(map()) :: %{q: String.t(), show: String.t(), page: pos_integer()}
  def view(params) do
    search = Search.term(params["q"]) || ""

    %{
      q: search,
      show: if(params["show"] == "all", do: "all", else: "in_use"),
      page: PagedRelation.requested(params, "page")
    }
  end

  @doc "The query the channel directory reads for `view/1`."
  @spec query(map()) :: map()
  def query(%{q: search, show: show, page: page}),
    do: %{"q" => search, "show" => show, "page" => Integer.to_string(page)}

  @doc "The page body as HTML, as the route hands it to the shell."
  @spec html(map()) :: binary()
  def html(assigns) do
    assigns
    |> Map.put(:__changed__, nil)
    |> render()
    |> Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  attr(:channels, :map, required: true, doc: "One page of `ChannelDirectory.list/1`")
  attr(:view, :map, required: true)
  attr(:now, :any, default: nil)

  @doc "The list body: filters, then one row per channel or what would put one here."
  def render(assigns) do
    assigns =
      assigns
      |> assign_new(:now, fn -> nil end)
      |> then(&assign(&1, :now, &1.now || DateTime.utc_now()))
      |> then(&assign(&1, :items, &1.channels.items))

    ~H"""
    <div class="channels-page">
      <Kit.toolbar>
        <Components.filter_toolbar
          id="operator-search"
          path="/channels"
          label="Search channels"
          placeholder="Search channels"
          query={@view.q}
          filtered={@view.q != ""}
          disabled={@items == [] and @view.q == "" and @view.show == "all"}
          hidden={if @view.show == "all", do: [{"show", "all"}], else: []}
          clear={if @view.show == "all", do: "/channels?show=all", else: "/channels"}
        />
        <Kit.segmented
          label="Which channels"
          options={[
            {"In use", href(@view, "in_use"), @view.show == "in_use"},
            {"All", href(@view, "all"), @view.show == "all"}
          ]}
        />
      </Kit.toolbar>
      <Kit.entity_list :if={@items != []} label="Channels">
        <Kit.entity_row
          :for={item <- @items}
          id={"channel-" <> item.workspace_ref <> "-" <> item.channel_ref}
          icon={:hash}
          icon_tone={:info}
          name={channel_name(item.workspace_ref, item.channel_ref, item.incident_room)}
          href={Paths.channel(item.workspace_ref, item.channel_ref)}
          link_row
          state={
            state(item.membership, match?(%{open: true}, item[:incident_room]), item.channel_ref)
          }
          meta={meta(item, @now)}
        />
      </Kit.entity_list>
      <Components.pager
        page={@channels.page}
        pages={@channels.pages}
        path={&Paths.query("/channels", q: @view.q, show: show_param(@view), page: &1)}
        label="Channel pages"
        summary={"#{@channels.total} channels"}
      />
      <Kit.empty
        :if={@items == []}
        icon={if @view.q != "", do: :search, else: :hash}
        title={empty_title(@view)}
        text={empty_text(@view)}
      />
    </div>
    """
  end

  attr(:settings, :any, required: true, doc: "The settings view the shell already read")

  @doc """
  Where Slack stands, in the words the Slack page uses, with the one step
  that moves it forward. Once Slack is set up, a second row says how a
  channel Ryker joins takes part until it makes its own choice, and Change
  opens that setting on the Slack page.
  """
  def slack_status(assigns) do
    assigns =
      assign(assigns,
        integration: Integrations.read(:slack, assigns.settings),
        default: new_channels(assigns.settings)
      )

    ~H"""
    <div class="connection-card">
      <Integrations.line id="slack-status" key={:slack} integration={@integration} />
      <%!-- No space after the hidden words: Chrome lays that space out as a
      second item of the button and puts the button's icon gap before it, so
      Change drew 9px wider than Manage above it (Andrew, 2026-09-27). --%>
      <div :if={@default} id="new-channels-default" class="connection-line">
        <p><strong>New channels</strong> <span>{participation(@default)}</span></p>
        <.link
          navigate="/integrations/slack#new-channels"
          class="ui-button secondary"
        >Change<span class="sr-only"> what new channels do</span></.link>
      </div>
    </div>
    """
  end

  # The setting lives on the Slack page, which shows it once Slack's tokens
  # are verified; before that there is nothing to change it on.
  defp new_channels({:ok, view}) do
    if Integrations.slack(view).status != :not_set_up,
      do: view.snapshot.slack.default_participation
  end

  defp new_channels(_unread), do: nil

  @doc """
  How Ryker takes part in a channel, in the words people use for it.
  """
  @spec participation(atom()) :: String.t()
  def participation(:mentions), do: "Replies when mentioned"
  def participation(:proactive), do: "Joins relevant conversations"
  def participation(:shadow), do: "Watches quietly"

  @doc """
  A channel's state as a dot and a word: an open incident first, then
  whether Ryker is in it. A direct message has no membership to report.
  """
  @spec state(atom() | nil, boolean(), String.t()) :: {atom(), String.t()} | nil
  def state(_membership, true, _channel_ref), do: {:warn, "Incident open"}
  def state(:joined, _incident_open, _channel_ref), do: {:on, "Connected"}
  def state(:left, _incident_open, _channel_ref), do: {:off, "Disconnected"}
  def state(:deleted, _incident_open, _channel_ref), do: {:off, "Deleted"}
  def state(nil, _incident_open, "D" <> _direct), do: nil
  def state(nil, _incident_open, _channel_ref), do: {:off, "Not connected"}

  defp meta(item, now) do
    [
      if(item[:private], do: "Private"),
      if(item[:incident_room], do: "Incident room"),
      participation(item.participation),
      environment(item),
      if(item[:custom_instructions], do: "own instructions"),
      conversations(item.episodes),
      item.last_at &&
        ShortTime.time(%{__changed__: nil, at: item.last_at, now: now, prefix: "last active "})
    ]
  end

  # An incident room keeps what it was opened with, so the list names no
  # environment for it; any other channel says where its work runs.
  defp environment(%{environment_source: :incident_room}), do: nil

  defp environment(%{environment_name: name}) when is_binary(name),
    do: works_in(%{__changed__: nil, name: name})

  defp environment(_none), do: "no environment"

  defp works_in(assigns), do: ~H"works in <strong>{@name}</strong>"

  defp conversations(0), do: "no conversations yet"
  defp conversations(1), do: "1 conversation"
  defp conversations(count), do: "#{count} conversations"

  defp show_param(%{show: "all"}), do: "all"
  defp show_param(_view), do: nil

  defp href(view, show) do
    query =
      [{"q", view.q}, {"show", if(show == "all", do: "all")}]
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

    if query == [], do: "/channels", else: Paths.query("/channels", query)
  end

  defp empty_title(%{q: search}) when search != "", do: "No channels match \"#{search}\""
  defp empty_title(%{show: "in_use"}), do: "Ryker is not in any channel now"
  defp empty_title(_view), do: "No channels yet"

  defp empty_text(%{q: search, show: "in_use"}) when search != "",
    do: "Try another name, or look under All for channels Ryker has left."

  defp empty_text(%{q: search}) when search != "", do: "Try another name or clear the search."

  # All can hold channels Ryker left or never joined, such as an incident
  # room nobody recorded it in, so In use never claims there are none.
  defp empty_text(%{show: "in_use"}) do
    "Invite Ryker to a Slack channel with /invite, and the channel appears here with how Ryker takes part in it. Channels Ryker is not in are under All."
  end

  defp empty_text(_view) do
    "Invite Ryker to a Slack channel with /invite, and the channel appears here with how Ryker takes part in it."
  end
end
