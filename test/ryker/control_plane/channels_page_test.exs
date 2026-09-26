defmodule Ryker.ControlPlane.ChannelsPageTest do
  @moduledoc """
  The Channels list: one search box and an In use / All choice over Kit rows
  that name each channel, say whether Ryker is in it, and how it takes part,
  in the words people use.
  """
  use Ryker.DataCase, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Ryker.ControlPlane.{ChannelDirectory, ChannelsPage, Pages, SettingsView}
  alias Ryker.Credentials
  alias Ryker.Fixtures.SavedEntities
  alias Ryker.Records
  alias Ryker.Settings
  alias Ryker.Slack.{ChannelConfigurationChangeset, IncidentRoomChangeset}
  alias Ryker.Slack.Names

  @now ~U[2026-09-24 12:00:00Z]
  @actor "control-plane:local"

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
      assert LazyHTML.text(state) == "Connected"
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

      # Andrew, 2026-09-26: "Ryker is in" read as a sentence cut short, not a
      # state. A channel is connected or it is not, as a service is.
      assert states == [
               {"Incident open", ["warn"]},
               {"Disconnected", ["off"]},
               {"Deleted", ["off"]},
               {"Not connected", ["off"]},
               {"", []}
             ]

      meta = [%{@channel | private: true, incident_room: %{status: :closed, open: false}}]
      text = meta |> render() |> LazyHTML.query("p.entity-meta") |> LazyHTML.text() |> squeeze()
      assert text =~ "Private · Incident room · Replies when mentioned"
    end

    test "an empty list says what would put a channel here, and a search miss says so" do
      in_use = render([], %{})

      # QA re-test, 2026-09-26: In use said "Ryker is not in any channel yet"
      # while All listed a channel. It says Ryker is in none now, and where
      # the others are.
      assert LazyHTML.query(in_use, ".entity-empty-title") |> LazyHTML.text() ==
               "Ryker is not in any channel now."

      assert LazyHTML.query(in_use, ".entity-empty") |> LazyHTML.text() =~ "/invite"

      assert LazyHTML.query(in_use, ".entity-empty") |> LazyHTML.text() =~
               "Channels Ryker is not in are under All."

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

    test "the route asks the directory for the chosen view" do
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

      Pages.page(["channels"], %{"show" => "all"}, options)
      assert_received {:channels, %{"q" => "", "show" => "all"}}
    end
  end

  describe "the Slack card" do
    # Andrew, 2026-09-26: a "Defaults" button sat in the Channels header, and
    # it was not clear why it was on this page or what it did. What a new
    # channel does is said beside Slack now, and Change opens that setting.
    test "the page says what new channels do, not behind a Defaults button" do
      verified_slack!(:proactive)
      {:ok, view} = SettingsView.fetch()

      card =
        render_component(&ChannelsPage.slack_status/1, settings: {:ok, view})
        |> LazyHTML.from_fragment()

      row = LazyHTML.query(card, ".connection-card > #new-channels-default")

      assert row |> LazyHTML.text() |> squeeze() ==
               "New channels Joins relevant conversations Change what new channels do"

      assert Enum.count(LazyHTML.query(row, "a[href='/integrations/slack#new-channels']")) == 1

      page =
        Pages.page(["channels"], %{}, %{projection: %{channels: fn _params -> [@channel] end}})

      refute Map.has_key?(page, :action)
    end

    test "before Slack is set up there is no setting to change, so no row for it" do
      {:ok, _snapshot} = Settings.initialize(@actor)
      {:ok, view} = SettingsView.fetch()

      card =
        render_component(&ChannelsPage.slack_status/1, settings: {:ok, view})
        |> LazyHTML.from_fragment()

      assert card |> LazyHTML.query("#slack-status .state-word") |> LazyHTML.text() ==
               "Not connected"

      assert Enum.empty?(LazyHTML.query(card, "#new-channels-default"))
    end
  end

  describe "the directory" do
    test "search matches the channel name people see, not only Slack's ids" do
      # Searching "#infra" found nothing: the filter compared the phrase with
      # raw ids ("C0123…") and the repository, never with the name the row
      # showed.
      membership!("T123", "C456", :joined)
      membership!("T123", "C789", :joined)
      start_supervised!({Names, workspace: "T123", fetch: &name/1})

      for channel <- ["C456", "C789"] do
        Names.name("T123", channel)
        GenServer.call(Names, :refresh)
      end

      assert Names.name("T123", "C456") == "#infra"

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
      assert rooms["COPEN"] == %{status: :requested, open: true, channel_name: "ems-copen"}
      assert rooms["CCLOSED"] == %{status: :closed, open: false, channel_name: "ems-cclosed"}
      assert rooms["CARCHIVED"] == %{status: :blocked, open: false, channel_name: "ems-carchived"}
    end

    test "an incident room's channel Slack has not named yet goes by the name Ryker gave it" do
      # QA re-test, 2026-09-26: the room's channel read "Slack channel
      # C0DEMOROOM1" while the room's own page called it
      # #inc-checkout-readiness-probes.
      item = %{
        @channel
        | channel_ref: "CUNNAMEDROOM",
          incident_room: %{status: :investigating, open: true, channel_name: "inc-checkout"}
      }

      assert render([item]) |> LazyHTML.query(".entity-name") |> LazyHTML.text() =~
               "#inc-checkout"

      assert ChannelsPage.channel_name("T123", "CUNNAMEDROOM", item.incident_room) ==
               "#inc-checkout"

      assert ChannelsPage.channel_name("T123", "CUNNAMEDROOM", nil) =~ "CUNNAMEDROOM"
    end
  end

  defp name("C456"), do: {:ok, "infra"}
  defp name(_channel), do: {:ok, "payments"}

  # Verified Slack tokens and identity, as Connect leaves them.
  defp verified_slack!(participation) do
    {:ok, snapshot} = Settings.initialize(@actor)

    {:ok, _snapshot} =
      Settings.save_slack(
        %{
          enabled: false,
          workspace_ref: "T0123456789",
          workspace_name: "Acme",
          bot_ref: "A0123456789",
          bot_user_ref: "U0123456789",
          bot_name: "ryker",
          default_participation: participation
        },
        snapshot.installation.revision,
        @actor
      )

    for kind <- [:slack_app, :slack_bot] do
      {:ok, _} = Credentials.put(kind, "primary", "xoxb-test-token-long-enough", @actor)
      {:ok, _} = Credentials.verify(kind, "primary", :verified, @actor)
    end
  end

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
