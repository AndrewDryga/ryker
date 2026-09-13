defmodule Responder.ControlPlane.ChannelDetailTest do
  @moduledoc """
  The Channel detail is a bounded, read-only overview of one Slack conversation.

  Slack custody tables key on the raw team/channel pair while every
  cross-transport context table keys on the canonical `slack:T…` and
  `slack:T…:C…` refs. These tests hold that contract shut: a record scoped to a
  channel appears on that channel's page and nowhere else, recorded values are
  never collapsed into "unknown", and loading the page changes nothing.
  """
  use Responder.DataCase, async: false

  import Ecto.Query
  import Phoenix.ConnTest, only: [build_conn: 0, get: 2]
  import Phoenix.LiveViewTest
  import Plug.Test

  alias Responder.ControlPlane.{Actions, Activity, Endpoint, Projection, Router}
  alias Responder.Episodes
  alias Responder.Episodes.Episode
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Fixtures.SavedEntities
  alias Responder.Slack.{ChannelConfigurationChangeset, IncidentRoomChangeset}
  alias Responder.State.{ConversationSummary, Records, Schedule}

  @endpoint Endpoint
  @now ~U[2026-09-10 12:00:00.000000Z]
  @page_size 25

  test "a canonical summary appears only on the channel page it belongs to" do
    # Production carried four durable summaries for one channel and the page
    # said "No durable records": the projection compared the raw `T…` ref while
    # continuity intentionally stores `slack:T…`. Every raw/canonical join must
    # go through one tested scope value.
    for {workspace, channel} <- [{"T123", "C456"}, {"T123", "C999"}, {"T999", "C456"}] do
      membership!(workspace, channel, private: false, external_shared: false)
    end

    summary = summary!("slack:T123", "slack:T123:C456", situation: "Replication is stalled")

    assert page("/channels/T123/C456") =~ summary.ref
    refute page("/channels/T123/C999") =~ summary.ref
    refute page("/channels/T999/C456") =~ summary.ref

    assert {:ok, view} = Projection.channel("T123", "C456", %{})
    assert view.summaries.total == 1
    assert [%{ref: ref}] = view.summaries.items
    assert ref == summary.ref

    assert {:ok, other_channel} = Projection.channel("T123", "C999", %{})
    assert other_channel.summaries.total == 0
    assert {:ok, other_workspace} = Projection.channel("T999", "C456", %{})
    assert other_workspace.summaries.total == 0
  end

  test "recorded false and missing visibility values are told apart" do
    # `private=false` is a recorded fact. Rendering it as "public or unrecorded"
    # hid whether Slack ever told us, which is exactly what an operator checking
    # a leak needs to know.
    membership!("T123", "CPUBLIC", private: false, external_shared: false)
    membership!("T123", "CPRIVATE", private: true, external_shared: true)
    membership!("T123", "CUNKNOWN", private: nil, external_shared: nil)

    for {channel, visibility, shared} <- [
          {"CPUBLIC", "Public", "No"},
          {"CPRIVATE", "Private", "Yes"},
          {"CUNKNOWN", "Not recorded", "Not recorded"}
        ] do
      html = page("/channels/T123/#{channel}")
      assert fact(html, "Visibility") == visibility, "#{channel} visibility"
      assert fact(html, "Externally shared") == shared, "#{channel} external sharing"
    end

    assert {:ok, %{channel: %{membership: public}}} = Projection.channel("T123", "CPUBLIC", %{})
    assert public.private == false and public.external_shared == false
    assert {:ok, %{channel: %{membership: unknown}}} = Projection.channel("T123", "CUNKNOWN", %{})
    assert is_nil(unknown.private) and is_nil(unknown.external_shared)
  end

  test "the scope contract exposes raw and canonical refs side by side" do
    membership!("T123", "C456", private: false, external_shared: false)
    assert {:ok, view} = Projection.channel("T123", "C456", %{})

    assert %{
             workspace_ref: "T123",
             channel_ref: "C456",
             canonical_workspace_ref: "slack:T123",
             conversation_ref: "slack:T123:C456",
             repository_ref: nil
           } = view.scope

    html = page("/channels/T123/C456")
    assert html =~ "slack:T123:C456"
    assert html =~ "slack:T123"
    assert fact(html, "Channel") =~ "C456"
    assert fact(html, "Workspace") =~ "T123"
  end

  test "current configuration is projected exactly, not inferred" do
    membership!("T123", "C456",
      private: false,
      external_shared: false,
      generation: 3,
      joined_at: @now,
      left_at: nil
    )

    configuration!("T123", "C456",
      participation: :proactive,
      repository_ref: "responder",
      alert_policy: :offer,
      invite_user_refs: ["U1", "U2"],
      invite_user_group_refs: ["S1"],
      actor_ref: "U123",
      revision: 4,
      saved_at: @now
    )

    assert {:ok, view} = Projection.channel("T123", "C456", %{})

    assert %{
             status: :joined,
             generation: 3,
             joined_at: @now,
             left_at: nil,
             deleted_at: nil,
             private: false,
             external_shared: false
           } = view.channel.membership

    assert %{
             participation: :proactive,
             repository_ref: "responder",
             alert_policy: :offer,
             invite_user_refs: ["U1", "U2"],
             invite_user_group_refs: ["S1"],
             actor_ref: "U123",
             revision: 4,
             saved_at: @now
           } = view.channel.configuration

    assert view.scope.repository_ref == "responder"
    assert view.channel.repository == %{ref: "responder", source: :configuration}
    assert view.channel.kind == :channel

    assert [
             %{setting: :proactive, value: true, scope: :channel, revision: 4},
             %{setting: :shadow, value: false, scope: :channel, revision: 4}
           ] = view.participation

    html = page("/channels/T123/C456")
    assert fact(html, "Membership") =~ "Joined"
    assert fact(html, "Membership") =~ "generation 3"
    assert fact(html, "Participation") =~ "Proactive"
    assert fact(html, "Repository") =~ "responder"
    assert fact(html, "Alert policy") =~ "Offer"
    assert fact(html, "Additional users") =~ "U1"
    assert fact(html, "User groups") =~ "S1"
    assert fact(html, "Configured by") =~ "U123"
    assert fact(html, "Revision") =~ "4"
    assert fact(html, "Saved") =~ "10 Sep, 12:00 UTC"
  end

  test "unconfigured values are calm explicit empties, never a substituted default" do
    membership!("T123", "C456",
      private: false,
      external_shared: false,
      status: :left,
      left_at: DateTime.add(@now, 3_600, :second)
    )

    assert {:ok, view} = Projection.channel("T123", "C456", %{})
    assert is_nil(view.channel.configuration)
    assert is_nil(view.channel.incident_room)
    assert is_nil(view.channel.repository)
    assert [%{scope: :installation}, %{scope: :installation}] = view.participation

    html = page("/channels/T123/C456")
    assert fact(html, "Membership") =~ "Left"
    assert fact(html, "Participation") == "Not configured"
    assert fact(html, "Repository") == "Not configured"
    assert fact(html, "Alert policy") == "Not configured"
    assert fact(html, "Additional users") == "None"
    assert fact(html, "User groups") == "None"
    assert fact(html, "Revision") == "Not configured"
    assert html =~ "Installation default"
    refute "Incident room" in fact_labels(html)
  end

  test "an incident room channel shows its room and owning incident only when it is one" do
    source = SavedEntities.source!("slack:T123:C456")
    room = incident_room!(source, "T123", "CINCIDENT")
    membership!("T123", "CINCIDENT", private: true, external_shared: false)

    assert {:ok, view} = Projection.channel("T123", "CINCIDENT", %{})
    assert view.channel.kind == :incident_room

    assert %{
             ref: "incident-room:operator",
             title: "Operator incident",
             status: :blocked,
             channel_state: :active,
             private: true,
             repository_ref: "responder"
           } = view.channel.incident_room

    assert view.channel.incident_room.episode_ref == source.episode.key
    assert view.channel.repository == %{ref: "responder", source: :incident_room}
    assert view.scope.repository_ref == "responder"

    html = page("/channels/T123/CINCIDENT")
    assert html =~ "href=\"/incident-rooms/incident-room%3Aoperator\""
    assert fact(html, "Kind") == "Incident room"
    assert fact(html, "Room state") =~ "Active"
    refute html =~ room.prompt
    refute html =~ "private-incident-error"
  end

  test "a channel nobody recorded is not found, and a broken read is unavailable rather than empty" do
    assert Projection.channel("T123", "C456", %{}) == :not_found
    assert Projection.channel(nil, nil, %{}) == :not_found
    assert Projection.channel("T:123", "C456", %{}) == :not_found
    assert Projection.channel("", "C456", %{}) == :not_found
    assert page_status("/channels/T123/C456") == 404

    membership!("T123", "C456", private: false, external_shared: false)
    # Transactional DDL: the sandbox rolls this back with the test.
    Repo.query!("DROP TABLE conversation_summaries CASCADE")
    assert Projection.channel("T123", "C456", %{}) == {:error, :unavailable}
  end

  test "loading the page changes nothing and calls nobody" do
    membership!("T123", "C456", private: false, external_shared: false)
    summary!("slack:T123", "slack:T123:C456", recall_count: 4)
    handler = "channel-detail-no-external-request-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler,
      [:finch, :request, :start],
      fn event, _measurements, _metadata, _config ->
        send(test_pid, {:external_request, event})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    writes_before = transaction_writes()

    assert page_status("/channels/T123/C456") == 200
    assert page_status("/channels/T123/C456?summary_page=2&episode_page=3") == 200

    assert transaction_writes() == writes_before
    refute_received {:external_request, _}
    assert Repo.one!(from(summary in ConversationSummary, select: summary.recall_count)) == 4
  end

  test "nothing that must stay inside the host crosses the page boundary" do
    source = SavedEntities.source!("slack:T123:CINCIDENT")
    incident_room!(source, "T123", "CINCIDENT")
    membership!("T123", "CINCIDENT", private: true, external_shared: false)

    summary!("slack:T123", "slack:T123:CINCIDENT",
      situation: "Replication is stalled",
      source_dependencies: [%{"secret-dependency" => "must-not-render-dependency"}]
    )

    html = page("/channels/T123/CINCIDENT")

    for marker <- ~w(private-incident-prompt private-incident-error must-not-render-dependency) do
      refute html =~ marker, "#{marker} crossed the page boundary"
    end
  end

  describe "episode metric and pagination" do
    test "the episode count is an exact aggregate with a filtered link the reader can page through" do
      # The old page showed nine rows from a hidden 200-row sample and no
      # total, so a busy channel could not be told from a quiet one.
      membership!("T123", "C456", private: false, external_shared: false)
      membership!("T123", "C999", private: false, external_shared: false)
      episodes!("slack:T123:C456", 201)
      episodes!("slack:T123:C999", 2)

      assert {:ok, view} = Projection.channel("T123", "C456", %{})
      assert view.episodes.total == 201
      assert view.episodes.pages == 9
      assert length(view.episodes.items) == @page_size

      html = page("/channels/T123/C456")
      metric = html |> LazyHTML.from_document() |> LazyHTML.query(".channel-metrics a")
      assert LazyHTML.text(metric) =~ "201 episodes"

      [href] = LazyHTML.attribute(metric, "href")
      assert href == Activity.conversation_path("slack", "slack:T123:C456")
      %URI{path: "/activity", query: query} = URI.parse(href)
      params = URI.decode_query(query)
      assert params["conversation"] == "slack:T123:C456"
      assert params["transport"] == "slack"

      # The destination keeps the criterion and reaches every episode itself.
      directory = Activity.list(params)
      assert directory.total == 201
      assert directory.pages == 7
      last = Activity.list(Map.put(params, "page", "7"))
      assert length(last.items) == 21
      assert Enum.all?(directory.items, &(&1.conversation == "slack:T123:C456"))
    end

    test "every related collection pages exactly at 25 rows without losing a timestamp tie" do
      membership!("T123", "C456", private: false, external_shared: false)
      # The offers' source episode lives elsewhere so it is not a 27th episode.
      source = SavedEntities.source!("slack:T123:CSOURCE")
      episode_refs = episodes!("slack:T123:C456", 26, updated_at: @now)
      schedule_refs = schedules!(source, "slack:T123:C456", 26)
      summary_refs = for _ <- 1..26, do: summary!("slack:T123", "slack:T123:C456", []).ref

      for {section, key, refs} <- [
            {:episodes, "episode_page", episode_refs},
            {:schedules, "schedule_page", schedule_refs},
            {:summaries, "summary_page", summary_refs}
          ] do
        assert {:ok, first} = Projection.channel("T123", "C456", %{})
        assert {:ok, second} = Projection.channel("T123", "C456", %{key => "2"})
        first_page = Map.fetch!(first, section)
        second_page = Map.fetch!(second, section)

        assert %{total: 26, pages: 2, page: 1, key: ^key} = first_page, "#{section} first page"
        assert %{total: 26, pages: 2, page: 2, key: ^key} = second_page, "#{section} second page"
        assert length(first_page.items) == @page_size
        assert length(second_page.items) == 1

        seen = Enum.map(first_page.items ++ second_page.items, & &1.ref)
        assert Enum.sort(seen) == Enum.sort(refs), "#{section} pages must partition the rows"

        # Invalid and out-of-range pages resolve to a valid page, never to an
        # empty section.
        for value <- ["0", "-1", "two", "", "2.5", ["2"]] do
          assert {:ok, view} = Projection.channel("T123", "C456", %{key => value})
          assert Map.fetch!(view, section).page == 1, "#{section} with #{inspect(value)}"
          assert length(Map.fetch!(view, section).items) == @page_size
        end

        assert {:ok, past_end} = Projection.channel("T123", "C456", %{key => "40"})
        assert Map.fetch!(past_end, section).page == 2
        assert length(Map.fetch!(past_end, section).items) == 1
      end
    end

    test "paging one section preserves the others and lands on its own anchor" do
      membership!("T123", "C456", private: false, external_shared: false)
      episodes!("slack:T123:C456", 26, updated_at: @now)
      for _ <- 1..26, do: summary!("slack:T123", "slack:T123:C456", [])

      html = page("/channels/T123/C456?episode_page=2&summary_page=2&schedule_page=7&q=ignored")

      assert {:ok, view} =
               Projection.channel("T123", "C456", %{
                 "episode_page" => "2",
                 "summary_page" => "2"
               })

      assert view.episodes.page == 2 and view.summaries.page == 2 and view.schedules.page == 1

      document = LazyHTML.from_document(html)

      assert document |> LazyHTML.query("#episodes .pagination span") |> LazyHTML.text() =~
               "Page 2 of 2"

      assert document |> LazyHTML.query("#summaries .pagination span") |> LazyHTML.text() =~
               "Page 2 of 2"

      assert document |> LazyHTML.query("#schedules .pagination") |> LazyHTML.to_tree() == []

      [previous_episodes] =
        document |> LazyHTML.query("#episodes .pagination a") |> LazyHTML.attribute("href")

      assert previous_episodes == "/channels/T123/C456?summary_page=2#episodes"

      [previous_summaries] =
        document |> LazyHTML.query("#summaries .pagination a") |> LazyHTML.attribute("href")

      assert previous_summaries == "/channels/T123/C456?episode_page=2#summaries"

      first = page("/channels/T123/C456") |> LazyHTML.from_document()

      [next_episodes] =
        first |> LazyHTML.query("#episodes .pagination a") |> LazyHTML.attribute("href")

      assert next_episodes == "/channels/T123/C456?episode_page=2#episodes"
      refute html =~ "ignored"
    end

    test "a row deleted between requests moves the reader to the last valid page, not to an empty one" do
      membership!("T123", "C456", private: false, external_shared: false)
      [first | _] = for _ <- 1..26, do: summary!("slack:T123", "slack:T123:C456", [])
      assert {:ok, view} = Projection.channel("T123", "C456", %{"summary_page" => "2"})
      assert view.summaries.page == 2

      Repo.delete_all(from(summary in ConversationSummary, where: summary.id == ^first.id))
      assert {:ok, view} = Projection.channel("T123", "C456", %{"summary_page" => "2"})
      assert %{page: 1, pages: 1, total: 25} = view.summaries
      assert length(view.summaries.items) == @page_size

      html = page("/channels/T123/C456?summary_page=2")
      refute html =~ "No conversation summaries are retained"
    end

    test "a channel with only paged-out rows never reads as empty" do
      membership!("T123", "C456", private: false, external_shared: false)
      summary!("slack:T123", "slack:T123:C456", [])
      html = page("/channels/T123/C456?summary_page=9")
      refute html =~ "No conversation summaries are retained"
      assert html =~ "1 summary"
    end
  end

  describe "live routing" do
    setup do
      start_supervised!(
        {Endpoint,
         [
           server: false,
           secret_key_base: String.duplicate("s", 64),
           pubsub_server: Responder.ControlPlane.PubSub,
           live_view: [signing_salt: "channel-test"],
           check_origin: ["//localhost:4321"],
           url: [host: "localhost", port: 4321],
           control_plane: %{
             actions: Actions.callbacks(),
             csrf_secret: String.duplicate("s", 32),
             observability: %{},
             projection: Projection.callbacks()
           }
         ]}
      )

      :ok
    end

    test "a refresh on page two keeps every section where the reader left it" do
      membership!("T123", "C456", private: false, external_shared: false)
      episodes!("slack:T123:C456", 26, updated_at: @now)
      for _ <- 1..26, do: summary!("slack:T123", "slack:T123:C456", [])

      conn = build_conn() |> Map.put(:host, "localhost")
      {:ok, view, html} = live(conn, "/channels/T123/C456?episode_page=2&summary_page=2")
      assert pages(html) == %{"episodes" => "Page 2 of 2", "summaries" => "Page 2 of 2"}

      send(view.pid, :reconcile)
      assert pages(render(view)) == %{"episodes" => "Page 2 of 2", "summaries" => "Page 2 of 2"}
      render_click(view, "refresh")
      assert pages(render(view)) == %{"episodes" => "Page 2 of 2", "summaries" => "Page 2 of 2"}

      {:ok, _view, first} = live(conn, "/channels/T123/C456")
      assert pages(first) == %{"episodes" => "Page 1 of 2", "summaries" => "Page 1 of 2"}
    end

    defp pages(html) do
      document = LazyHTML.from_document(html)

      for section <- ~w(episodes summaries), into: %{} do
        {section,
         document
         |> LazyHTML.query("##{section} .pagination span")
         |> LazyHTML.text()
         |> String.trim()}
      end
    end
  end

  defp membership!(workspace, channel, attributes) do
    %{
      channel_ref: channel,
      generation: 1,
      id: Ecto.UUID.generate(),
      joined_at: @now,
      status: :joined,
      workspace_ref: workspace
    }
    |> Map.merge(Map.new(attributes))
    |> ChannelConfigurationChangeset.membership()
    |> Repo.insert!()
  end

  defp episodes!(conversation, count, options \\ []) do
    refs =
      for index <- 1..count do
        id = Ecto.UUID.generate()

        {:ok, _} =
          Episodes.apply(
            EpisodeFixtures.admit_input(%{
              destination: %{
                conversation_ref: conversation,
                thread_ref: "1.#{index}",
                transport: "slack"
              },
              episode_id: id,
              episode_key: "channel:#{index}:#{id}",
              native_input_id: "channel:#{index}:#{id}",
              turn_ref: "turn:#{id}"
            })
          )

        "channel:#{index}:#{id}"
      end

    if updated_at = options[:updated_at] do
      Repo.update_all(from(episode in Episode, where: episode.key in ^refs),
        set: [updated_at: updated_at]
      )
    end

    refs
  end

  defp schedules!(source, destination, count) do
    refs =
      for index <- 1..count,
          do:
            SavedEntities.schedule!(source, "Schedule #{index}", index, destination: destination).ref

    # One shared next run: the pager must fall back to the unique id.
    Repo.update_all(from(schedule in Schedule, where: schedule.ref in ^refs),
      set: [next_occurrence_at: @now]
    )

    refs
  end

  defp configuration!(workspace, channel, attributes) do
    %{
      channel_ref: channel,
      id: Ecto.UUID.generate(),
      invite_user_group_refs: [],
      invite_user_refs: [],
      repository_ref: nil,
      alert_policy: :reply,
      revision: 1,
      saved_at: @now,
      workspace_ref: workspace
    }
    |> Map.merge(Map.new(attributes))
    |> ChannelConfigurationChangeset.configuration()
    |> Repo.insert!()
  end

  defp summary!(workspace, conversation, attributes) do
    attributes = Map.new(attributes)
    sequence = System.unique_integer([:positive, :monotonic])

    state = %{
      "active_topics" => ["database"],
      "decisions" => [],
      "evidence_refs" => [],
      "goal" => "Restore the primary",
      "open_loops" => [],
      "participants" => ["U1"],
      "purpose" => "Incident response",
      "situation" => Map.get(attributes, :situation, "Situation #{sequence}"),
      "topology" => [],
      "unresolved_questions" => []
    }

    Repo.insert!(%ConversationSummary{
      id: Ecto.UUID.generate(),
      ref: "summary:#{sequence}",
      identity_key: Responder.CanonicalJSON.digest("identity:#{sequence}"),
      transport: "slack",
      workspace_ref: workspace,
      conversation_ref: conversation,
      thread_ref: Map.get(attributes, :thread_ref),
      visibility: :conversation,
      state: state,
      source_dependencies: Map.get(attributes, :source_dependencies, []),
      state_fingerprint: String.duplicate("a", 64),
      source_result_ref: "result:#{sequence}",
      recall_count: Map.get(attributes, :recall_count, 0),
      inserted_at: Map.get(attributes, :updated_at, @now),
      updated_at: Map.get(attributes, :updated_at, @now)
    })
  end

  defp incident_room!(source, workspace, channel) do
    {:ok, record} =
      Records.create(Records.token(source.turn), "incident-room-offer", "progress", %{
        "next_due_at" => nil,
        "phase" => "investigating",
        "summary" => "Incident evidence."
      })

    %{
      attempt_count: 1,
      bot_user_ref: "U-BOT",
      channel_name: "ems-operator-incident",
      channel_ref: channel,
      channel_state: :active,
      channel_state_changed_at: @now,
      channel_state_event_ref: "channel-state:operator",
      confirmation_ref: "incident-confirmation:operator",
      episode_id: source.episode.id,
      id: Ecto.UUID.generate(),
      invite_user_group_refs: [],
      invite_user_refs: ["U123"],
      last_error_code: "coop_error",
      last_error_detail: "private-incident-error",
      policy: "incident-investigate",
      policy_digest: String.duplicate("c", 64),
      private: true,
      prompt: "Investigate private-incident-prompt.",
      reconciled_channel_state: :active,
      record_id: record.id,
      ref: "incident-room:operator",
      repository_ref: "responder",
      requested_at: @now,
      requested_by_actor_ref: "U123",
      source_channel_ref: "C456",
      source_episode_id: source.episode.id,
      source_message_ref: "1787832000.000100",
      status: :blocked,
      title: "Operator incident",
      topic: "Operator incident room",
      workspace_ref: workspace
    }
    |> IncidentRoomChangeset.insert()
    |> Repo.insert!()
  end

  defp page(path) do
    conn = request(path)
    assert conn.status == 200, "#{path} answered #{conn.status}"
    conn.resp_body
  end

  defp page_status(path), do: request(path).status

  defp request(path) do
    options =
      Router.init(%{
        actions: %{},
        csrf_secret: String.duplicate("s", 32),
        observability: %{},
        projection: Projection.callbacks()
      })

    :get
    |> conn(path)
    |> Map.put(:host, "localhost")
    |> Map.put(:remote_ip, {127, 0, 0, 1})
    |> Router.call(options)
  end

  defp fact_labels(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#configuration dl > div > dt")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  # The text of the definition beside one configuration label.
  defp fact(html, label) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#configuration dl > div")
    |> Enum.find(fn pair ->
      pair |> LazyHTML.query("dt") |> LazyHTML.text() |> String.trim() == label
    end)
    |> case do
      nil -> flunk("no #{inspect(label)} fact on the page")
      pair -> pair |> LazyHTML.query("dd") |> LazyHTML.text() |> String.trim() |> squeeze()
    end
  end

  defp squeeze(text), do: String.replace(text, ~r/\s+/, " ")

  # Tuples written inside the sandbox transaction so far: any page load that
  # inserts, updates or deletes anything moves this number.
  defp transaction_writes do
    %{rows: [[writes]]} =
      Repo.query!(
        "SELECT COALESCE(SUM(n_tup_ins + n_tup_upd + n_tup_del), 0)::bigint FROM pg_stat_xact_user_tables"
      )

    writes
  end
end
