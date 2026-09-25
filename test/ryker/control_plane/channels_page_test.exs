defmodule Ryker.ControlPlane.ChannelsPageTest do
  @moduledoc """
  The Channels list: one search box and an In use / All choice over Kit rows
  that name each channel, say whether Ryker is in it, and how it takes part,
  in the words people use.
  """
  use Ryker.DataCase, async: false

  alias Ryker.ControlPlane.{ChannelDirectory, ChannelsPage, Pages, SlackNames}
  alias Ryker.Fixtures.SavedEntities
  alias Ryker.Settings
  alias Ryker.Slack.{ChannelConfigurationChangeset, IncidentRoomChangeset}
  alias Ryker.State.Records

  @now ~U[2026-09-24 12:00:00Z]

  @channel %{
    channel_ref: "C456",
    custom_instructions: true,
    episodes: 2,
    external_shared: false,
    incident_room: nil,
    last_at: ~U[2026-08-28 12:00:00Z],
    membership: :joined,
    participation: :mentions,
    participation_source: :channel,
    private: false,
    environment_ref: "payments",
    environment_name: "Payments",
    environment_source: :channel,
    workspace_ref: "T123"
  }

  describe "the list" do
    test "channels are filters over Kit rows, never a comparison table" do
      # Before 2026-09-24 the list was a seven-column table of raw words
      # ("Joined", "Mentions", "Global + channel") with the Slack ids under
      # each name; Andrew asked for rows that read as sentences.
      document = render([@channel, %{@channel | channel_ref: "C789", membership: :left}])

      assert outline(document, "div.channels-page > *") == [
               "div.kit-toolbar",
               "div.entity-list"
             ]

      assert outline(document, "div.kit-toolbar > *") == [
               "form.filter-toolbar",
               "nav.segmented"
             ]

      assert Enum.count(LazyHTML.query(document, "article.entity-row[role=listitem]")) == 2
      assert Enum.empty?(LazyHTML.query(document, "table, h1, h2, .page-help, .result-count"))
    end

    test "a row names the channel, links to its page and says how Ryker takes part in words" do
      document = render([@channel])
      row = LazyHTML.query(document, "article.entity-row")

      name = LazyHTML.query(row, "h3.entity-name a[href='/channels/T123/C456']")
      assert LazyHTML.text(name) =~ "C456"

      state = LazyHTML.query(row, ".entity-side .state-word")
      assert LazyHTML.text(state) == "Ryker is in"
      assert LazyHTML.attribute(state, "data-tone") == ["on"]

      meta = row |> LazyHTML.query("p.entity-meta") |> LazyHTML.text() |> squeeze()

      assert meta ==
               "Replies when mentioned · works in Payments · own instructions · 2 conversations · last active 28 Aug"

      assert LazyHTML.query(row, "p.entity-meta strong") |> LazyHTML.text() == "Payments"

      last = LazyHTML.query(row, "p.entity-meta time")
      assert LazyHTML.attribute(last, "datetime") == ["2026-08-28T12:00:00Z"]
      assert LazyHTML.attribute(last, "title") == ["28 Aug 2026, 12:00 UTC"]
      refute LazyHTML.text(document) =~ "Global + channel"
      refute LazyHTML.text(document) =~ "Mentions"
    end

    test "the three ways Ryker takes part have one set of words" do
      # The list, the channel page and the settings said "Mentions", "Only
      # when mentioned" and "Reply when mentioned" for the same choice.
      assert ChannelsPage.participation(:mentions) == "Replies when mentioned"
      assert ChannelsPage.participation(:proactive) == "Joins relevant conversations"
      assert ChannelsPage.participation(:shadow) == "Watches quietly"

      for {participation, words} <- [
            {:proactive, "Joins relevant conversations"},
            {:shadow, "Watches quietly"}
          ] do
        meta =
          [%{@channel | participation: participation}]
          |> render()
          |> LazyHTML.query("p.entity-meta")
          |> LazyHTML.text()

        assert meta =~ words
      end
    end

    test "an open incident needs a person; a left or deleted channel is finished" do
      states =
        [
          %{@channel | incident_room: %{status: :blocked, open: true}},
          %{@channel | channel_ref: "CLEFT", membership: :left},
          %{@channel | channel_ref: "CGONE", membership: :deleted},
          %{@channel | channel_ref: "CNEVER", membership: nil},
          %{@channel | channel_ref: "DDIRECT", membership: nil}
        ]
        |> render()
        |> LazyHTML.query("article.entity-row")
        |> Enum.map(fn row ->
          state = LazyHTML.query(row, ".state-word")
          {LazyHTML.text(state), LazyHTML.attribute(state, "data-tone")}
        end)

      assert states == [
               {"Incident open", ["warn"]},
               {"Ryker left", ["off"]},
               {"Deleted", ["off"]},
               {"Not joined", ["off"]},
               {"", []}
             ]

      meta = [%{@channel | private: true, incident_room: %{status: :closed, open: false}}]
      text = meta |> render() |> LazyHTML.query("p.entity-meta") |> LazyHTML.text() |> squeeze()
      assert text =~ "Private · Incident room · Replies when mentioned"
    end

    test "an empty list says what would put a channel here, and a search miss says so" do
      in_use = render([], %{})

      assert LazyHTML.query(in_use, ".entity-empty-title") |> LazyHTML.text() =~
               "not in any channel"

      assert LazyHTML.query(in_use, ".entity-empty") |> LazyHTML.text() =~ "/invite"

      all = render([], %{"show" => "all"})
      assert LazyHTML.query(all, ".entity-empty-title") |> LazyHTML.text() == "No channels yet."

      assert LazyHTML.query(all, "form.filter-toolbar input[type=search][disabled]")
             |> Enum.count() == 1

      miss = render([], %{"q" => "absent"})

      assert LazyHTML.query(miss, ".entity-empty-title") |> LazyHTML.text() ==
               "No channels match “absent”."

      assert Enum.empty?(LazyHTML.query(miss, "form.filter-toolbar input[disabled]"))
    end

    test "the In use and All views keep the search, and the search keeps the view" do
      in_use = render([@channel], %{"q" => "infra"})

      assert LazyHTML.query(in_use, "nav.segmented a") |> LazyHTML.attribute("href") == [
               "/channels?q=infra",
               "/channels?q=infra&show=all"
             ]

      assert LazyHTML.query(in_use, "nav.segmented a[aria-current=page]") |> LazyHTML.text() ==
               "In use"

      assert Enum.empty?(LazyHTML.query(in_use, "form.filter-toolbar input[name=show]"))

      assert LazyHTML.query(in_use, "a.filter-clear") |> LazyHTML.attribute("href") == [
               "/channels"
             ]

      all = render([@channel], %{"q" => "infra", "show" => "all"})

      assert LazyHTML.query(all, "nav.segmented a[aria-current=page]") |> LazyHTML.text() == "All"

      assert LazyHTML.query(all, "form.filter-toolbar input[type=hidden][name=show]")
             |> LazyHTML.attribute("value") == ["all"]

      assert LazyHTML.query(all, "a.filter-clear") |> LazyHTML.attribute("href") == [
               "/channels?show=all"
             ]
    end

    test "the route asks the directory for the chosen view and offers the channel defaults" do
      parent = self()

      options = %{
        projection: %{
          channels: fn params ->
            send(parent, {:channels, params})
            [@channel]
          end
        }
      }

      page = Pages.page(["channels"], %{"q" => "infra"}, options)
      assert_received {:channels, %{"q" => "infra", "show" => "in_use"}}

      assert page.title == "Channels"
      assert page.description == "Slack channels Ryker is in, and how it takes part in each one."

      action = LazyHTML.from_fragment(page.action)

      assert LazyHTML.query(action, "a[href='/integrations/slack#new-channels']")
             |> LazyHTML.text() ==
               "Defaults"

      Pages.page(["channels"], %{"show" => "all"}, options)
      assert_received {:channels, %{"q" => "", "show" => "all"}}
    end
  end

  describe "the directory" do
    test "search matches the channel name people see, not only Slack's ids" do
      # Searching "#infra" found nothing: the filter compared the phrase with
      # raw ids ("C0123…") and the repository, never with the name the row
      # showed.
      membership!("T123", "C456", :joined)
      membership!("T123", "C789", :joined)
      start_supervised!({SlackNames, workspace: "T123", fetch: &name/1})

      for channel <- ["C456", "C789"] do
        SlackNames.name("T123", channel)
        GenServer.call(SlackNames, :refresh)
      end

      assert SlackNames.name("T123", "C456") == "#infra"

      for q <- ["#infra", "INFRA", "C456"] do
        assert [%{channel_ref: "C456"}] = ChannelDirectory.list(%{"q" => q}), q
      end

      assert [%{channel_ref: "C789"}] = ChannelDirectory.list(%{"q" => "payments"})
    end

    test "In use lists only the channels Ryker is in; All keeps the ones it left" do
      membership!("T123", "CJOINED", :joined)
      membership!("T123", "CLEFT", :left)
      configuration!("T123", "CCONFIGURED", participation: :proactive)

      assert Enum.map(ChannelDirectory.list(%{"show" => "in_use"}), & &1.channel_ref) == [
               "CJOINED"
             ]

      assert ChannelDirectory.list(%{"show" => "all"})
             |> Enum.map(& &1.channel_ref)
             |> Enum.sort() ==
               ["CCONFIGURED", "CJOINED", "CLEFT"]

      # Setup counts channels with no view chosen, so no view is "All".
      assert length(ChannelDirectory.list(%{})) == 3
    end

    test "each channel says which environment its work runs in" do
      # Channels choose an environment, not a repository. One that chose none
      # works without code or Emisar, and says so; one Ryker holds no setting
      # for works in the default environment; an incident room keeps what it
      # was opened with and names none.
      {:ok, snapshot} = Settings.initialize("control-plane:local")

      {:ok, snapshot} =
        Settings.put_environment(
          %{ref: "production", display_name: "Production", repositories: [], is_default: true},
          snapshot.installation.revision,
          "control-plane:local"
        )

      {:ok, _snapshot} =
        Settings.put_environment(
          %{ref: "staging", display_name: "Staging", repositories: []},
          snapshot.installation.revision,
          "control-plane:local"
        )

      configuration!("T123", "CSTAGE", environment_ref: "staging")
      configuration!("T123", "CNONE", [])
      membership!("T123", "CUNSET", :joined)
      membership!("T123", "CROOM", :joined)
      room!("T123", "CROOM", :requested, :active)

      rows = Map.new(ChannelDirectory.list(%{}), &{&1.channel_ref, &1})

      assert %{
               environment_ref: "staging",
               environment_name: "Staging",
               environment_source: :channel
             } =
               rows["CSTAGE"]

      assert %{environment_ref: nil, environment_source: :channel} = rows["CNONE"]
      assert %{environment_ref: "production", environment_source: :default} = rows["CUNSET"]
      assert %{environment_ref: nil, environment_source: :incident_room} = rows["CROOM"]

      document = render(Map.values(rows))

      meta = fn channel ->
        document
        |> LazyHTML.query("#channel-T123-#{channel} p.entity-meta")
        |> LazyHTML.text()
        |> squeeze()
      end

      assert meta.("CSTAGE") =~ "works in Staging"
      assert meta.("CNONE") =~ "no environment"
      assert meta.("CUNSET") =~ "works in Production"
      refute meta.("CROOM") =~ "environment"
      refute meta.("CROOM") =~ "works in"

      assert [%{channel_ref: "CSTAGE"}] = ChannelDirectory.list(%{"q" => "staging"})
    end

    test "a channel that never chose follows the installation default, and says so" do
      {:ok, _snapshot} = Settings.initialize("control-plane:local")
      Repo.update_all(Settings.Slack, set: [default_participation: :shadow])
      membership!("T123", "CINHERITS", :joined)
      configuration!("T123", "CCHOSE", participation: :proactive)

      rows = Map.new(ChannelDirectory.list(%{}), &{&1.channel_ref, &1})
      assert %{participation: :shadow, participation_source: :installation} = rows["CINHERITS"]
      assert %{participation: :proactive, participation_source: :channel} = rows["CCHOSE"]
    end

    test "an incident room is open until it closes or its channel is archived" do
      membership!("T123", "COPEN", :joined)
      membership!("T123", "CCLOSED", :joined)
      membership!("T123", "CARCHIVED", :joined)
      room!("T123", "COPEN", :requested, :active)
      room!("T123", "CCLOSED", :closed, :active)
      room!("T123", "CARCHIVED", :blocked, :archived)

      rooms = Map.new(ChannelDirectory.list(%{}), &{&1.channel_ref, &1.incident_room})
      assert rooms["COPEN"] == %{status: :requested, open: true}
      assert rooms["CCLOSED"] == %{status: :closed, open: false}
      assert rooms["CARCHIVED"] == %{status: :blocked, open: false}
    end
  end

  defp name("C456"), do: {:ok, "infra"}
  defp name(_channel), do: {:ok, "payments"}

  defp render(items, params \\ %{}) do
    %{items: items, view: ChannelsPage.view(params), now: @now}
    |> ChannelsPage.html()
    |> LazyHTML.from_fragment()
  end

  defp membership!(workspace, channel, status) do
    %{
      channel_ref: channel,
      generation: 1,
      id: Ecto.UUID.generate(),
      joined_at: @now,
      left_at: if(status == :left, do: @now),
      private: false,
      external_shared: false,
      status: status,
      workspace_ref: workspace
    }
    |> ChannelConfigurationChangeset.membership()
    |> Repo.insert!()
  end

  defp configuration!(workspace, channel, attributes) do
    %{
      alert_policy: :reply,
      channel_ref: channel,
      id: Ecto.UUID.generate(),
      invite_user_group_refs: [],
      invite_user_refs: [],
      revision: 1,
      saved_at: @now,
      workspace_ref: workspace
    }
    |> Map.merge(Map.new(attributes))
    |> ChannelConfigurationChangeset.configuration()
    |> Repo.insert!()
  end

  defp room!(workspace, channel, status, channel_state) do
    source = SavedEntities.source!("slack:#{workspace}:source-#{channel}")

    {:ok, record} =
      Records.create(
        Records.token(source.turn),
        "incident-room-offer",
        "progress",
        %{"next_due_at" => nil, "phase" => "investigating", "summary" => "Evidence."}
      )

    %{
      attempt_count: 1,
      bot_user_ref: "U-BOT",
      channel_name: "ems-" <> String.downcase(channel),
      channel_ref: channel,
      channel_state: channel_state,
      channel_state_changed_at: @now,
      channel_state_event_ref: "channel-state:" <> channel,
      confirmation_ref: "incident-confirmation:" <> channel,
      episode_id: source.episode.id,
      id: Ecto.UUID.generate(),
      invite_user_group_refs: [],
      invite_user_refs: [],
      policy: "incident-investigate",
      policy_digest: String.duplicate("c", 64),
      private: true,
      prompt: "Investigate.",
      reconciled_channel_state: channel_state,
      record_id: record.id,
      ref: "incident-room:" <> channel,
      repository_ref: "ryker",
      requested_at: @now,
      requested_by_actor_ref: "U123",
      source_channel_ref: "C456",
      source_episode_id: source.episode.id,
      source_message_ref: "1787832000.000100",
      status: status,
      title: "Incident in " <> channel,
      topic: "Incident",
      workspace_ref: workspace
    }
    |> IncidentRoomChangeset.insert()
    |> Repo.insert!()
  end

  defp squeeze(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  # "tag.first-class" for each matched element, in document order.
  defp outline(document, selector) do
    nodes = LazyHTML.query(document, selector)

    nodes
    |> LazyHTML.tag()
    |> Enum.zip(LazyHTML.attributes(nodes))
    |> Enum.map(fn {tag, attributes} ->
      case List.keyfind(attributes, "class", 0) do
        {"class", class} -> tag <> "." <> hd(String.split(class))
        nil -> tag
      end
    end)
  end
end
