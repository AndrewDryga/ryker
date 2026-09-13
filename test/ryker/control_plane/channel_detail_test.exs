defmodule Ryker.ControlPlane.ChannelDetailTest do
  @moduledoc """
  The Channel detail is a bounded, read-only overview of one Slack conversation.

  Slack custody tables key on the raw team/channel pair while every
  cross-transport context table keys on the canonical `slack:T…` and
  `slack:T…:C…` refs. These tests hold that contract shut: a record scoped to a
  channel appears on that channel's page and nowhere else, recorded values are
  never collapsed into "unknown", and loading the page changes nothing.
  """
  use Ryker.DataCase, async: false

  import Ecto.Query
  import Phoenix.ConnTest, only: [build_conn: 0, get: 2]
  import Phoenix.LiveViewTest
  import Plug.Test

  alias Ryker.Accounting.Execution

  alias Ryker.ControlPlane.{
    Actions,
    Activity,
    Endpoint,
    LearningActivity,
    Projection,
    Router,
    UsageProjection
  }

  alias Ryker.Episodes
  alias Ryker.Episodes.Episode
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.Knowledge, as: KnowledgeFixtures
  alias Ryker.Fixtures.SavedEntities
  alias Ryker.Ingress.Inbox
  alias Ryker.Learning.Batch
  alias Ryker.Slack.{ChannelConfigurationChangeset, IncidentRoomChangeset, Input}

  alias Ryker.State.{
    Behavior,
    ConversationKnowledge,
    ConversationRollup,
    ConversationSummary,
    ConversationSummaryDraft,
    MemoryEntry,
    Records,
    Schedule
  }

  alias Ryker.Work.Turn

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
      repository_ref: "ryker",
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
             repository_ref: "ryker",
             alert_policy: :offer,
             invite_user_refs: ["U1", "U2"],
             invite_user_group_refs: ["S1"],
             actor_ref: "U123",
             revision: 4,
             saved_at: @now
           } = view.channel.configuration

    assert view.scope.repository_ref == "ryker"
    assert view.channel.repository == %{ref: "ryker", source: :configuration}
    assert view.channel.kind == :channel

    assert [
             %{setting: :proactive, value: true, scope: :channel, revision: 4},
             %{setting: :shadow, value: false, scope: :channel, revision: 4}
           ] = view.participation

    html = page("/channels/T123/C456")
    assert fact(html, "Membership") =~ "Joined"
    assert fact(html, "Membership") =~ "generation 3"
    assert fact(html, "Participation") =~ "Proactive"
    assert fact(html, "Repository") =~ "ryker"
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
             repository_ref: "ryker"
           } = view.channel.incident_room

    assert view.channel.incident_room.episode_ref == source.episode.key
    assert view.channel.repository == %{ref: "ryker", source: :incident_room}
    assert view.scope.repository_ref == "ryker"

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

    rollup!("slack:T123", :conversation, "slack:T123:C456",
      expires_at: DateTime.add(@now, 30, :day),
      recall_count: 6
    )

    [key] = episodes!("slack:T123:C456", 1)
    KnowledgeFixtures.learn!(Repo.get_by!(Episode, key: key))
    batch!("slack:T123:C456", status: :deferred, error_code: "learning_judgment_deferred")

    execution!("slack:T123:C456",
      recorded_at: DateTime.add(DateTime.utc_now(), -1, :hour),
      tokens: {1, 0, 0, 0}
    )

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
    assert Repo.one!(from(rollup in ConversationRollup, select: rollup.recall_count)) == 6
  end

  test "nothing that must stay inside the host crosses the page boundary" do
    source = SavedEntities.source!("slack:T123:CINCIDENT")
    incident_room!(source, "T123", "CINCIDENT")
    membership!("T123", "CINCIDENT", private: true, external_shared: false)

    summary!("slack:T123", "slack:T123:CINCIDENT",
      situation: "Replication is stalled",
      source_dependencies: [%{"secret-dependency" => "must-not-render-dependency"}]
    )

    rollup!("slack:T123", :conversation, "slack:T123:CINCIDENT",
      expires_at: DateTime.add(@now, 30, :day),
      source_dependencies: [%{"secret" => "must-not-render-rollup-dependency"}],
      source_refs: ["must-not-render-source-ref"]
    )

    knowledge!("slack:T123:CINCIDENT",
      title: "Topic",
      source_dependencies: [%{"secret" => "must-not-render-knowledge-dependency"}]
    )

    batch!("slack:T123:CINCIDENT", status: :deferred, error_code: "must-not-render-raw-code")
    draft!(source, "must-not-render-draft")

    guidance!(source, "Guidance", "conversation",
      scope_ref: "slack:T123:CINCIDENT",
      text: "Visible guidance",
      extra: %{
        "api_token" => "must-not-render-token",
        "unknown_field" => "must-not-render-unknown"
      }
    )

    html = page("/channels/T123/CINCIDENT")
    assert html =~ "Visible guidance"

    for marker <-
          ~w(private-incident-prompt private-incident-error must-not-render-dependency
             must-not-render-rollup-dependency must-not-render-source-ref
             must-not-render-knowledge-dependency must-not-render-raw-code must-not-render-draft
             must-not-render-lease must-not-render-policy must-not-render-token
             must-not-render-unknown) do
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

    test "an empty relation says so once, not as a zero count above an empty line" do
      # "0 rollups" over "No compacted continuity is retained" is the same
      # fact twice; the count is for a list that has rows.
      membership!("T123", "C456", private: false, external_shared: false)
      document = page("/channels/T123/C456") |> LazyHTML.from_document()
      rollups = LazyHTML.query(document, "#rollups")
      assert LazyHTML.query(rollups, "p.empty-state") |> LazyHTML.text() =~ "No compacted"
      assert LazyHTML.query(rollups, "p.result-count") |> Enum.empty?()
    end

    test "a related episode is named by what was asked, with its key as the secondary fact" do
      # Deployed as 0.1.0-g865731d1, every row in Related episodes read
      # `ingress-input:dc0ef577-…` in monospace and nothing else: the key of
      # the request, not the request. The Activity page already names an
      # episode by its first input; the channel page uses the same title.
      membership!("T123", "C456", private: false, external_shared: false)
      [key] = episodes!("slack:T123:C456", 1)
      episode = Repo.get_by!(Episode, key: key)

      {:ok, input} =
        Input.new(%{
          actor: %{kind: :user, ref: "U1"},
          channel_ref: "C456",
          content: %{"text" => "checkout is returning 502s for about 8% of requests"},
          event_kind: :message,
          event_ref: "Ev-channel-episode-title",
          message_ref: "1.1",
          occurred_at: @now,
          revision: 1,
          thread_ref: nil,
          workspace_ref: "T123"
        })

      {:ok, %{entry: entry}} = Inbox.record(input)

      Repo.update_all(from(e in Inbox.Entry, where: e.id == ^entry.id),
        set: [
          episode_id: episode.id,
          status: :decided,
          decision_action: :start_episode,
          decision_ref: "decision:channel-episode-title",
          decision_fingerprint: String.duplicate("a", 64),
          decision_document: %{"action" => "start_episode", "episode_ref" => key}
        ]
      )

      rows =
        page("/channels/T123/C456")
        |> LazyHTML.from_document()
        |> LazyHTML.query("#episodes tbody tr")

      assert [row] = Enum.to_list(rows)
      link = LazyHTML.query(row, "td:first-child a")
      assert LazyHTML.text(link) =~ "checkout is returning 502s"
      refute LazyHTML.text(link) =~ key
      assert LazyHTML.query(row, "td:first-child code") |> LazyHTML.text() == key
    end

    test "every related collection pages exactly at 25 rows without losing a timestamp tie" do
      membership!("T123", "C456", private: false, external_shared: false)
      # The offers' source episode lives elsewhere so it is not a 27th episode.
      source = SavedEntities.source!("slack:T123:CSOURCE")
      episode_refs = episodes!("slack:T123:C456", 26, updated_at: @now)
      schedule_refs = schedules!(source, "slack:T123:C456", 26)
      summary_refs = for _ <- 1..26, do: summary!("slack:T123", "slack:T123:C456", []).ref
      future = DateTime.add(@now, 30, :day)

      # A rollup is unique per period, so each one starts on its own day.
      rollup_refs =
        for index <- 1..26,
            do:
              rollup!("slack:T123", :conversation, "slack:T123:C456",
                expires_at: future,
                period_start: DateTime.add(@now, -index, :day)
              ).ref

      knowledge_refs =
        for index <- 1..26, do: knowledge!("slack:T123:C456", title: "Topic #{index}").id

      learning_refs = for _ <- 1..26, do: batch!("slack:T123:C456", status: :no_change).id

      # One turn may hold only so many offers; each collection gets its own.
      rules_source = SavedEntities.source!("slack:T123:CSOURCE-rules")
      preferences_source = SavedEntities.source!("slack:T123:CSOURCE-preferences")
      guidance_source = SavedEntities.source!("slack:T123:CSOURCE-guidance")
      memory_source = SavedEntities.source!("slack:T123:CSOURCE-memory")

      rule_refs =
        for index <- 1..26,
            do: rule!(rules_source, "Rule #{index}", scope_ref: "slack:T123:C456").ref

      preference_refs =
        for index <- 1..26,
            do:
              preference!(preferences_source, "key_#{index}", "v", scope_ref: "slack:T123:C456").ref

      guidance_refs =
        for index <- 1..26,
            do:
              guidance!(guidance_source, "Guidance #{index}", "conversation",
                scope_ref: "slack:T123:C456"
              ).ref

      memory_refs =
        for index <- 1..26,
            do:
              memory!(memory_source, "subject #{index}", "v",
                scope_kind: :conversation,
                scope_ref: "slack:T123:C456"
              ).ref

      for {section, key, refs} <- [
            {:episodes, "episode_page", episode_refs},
            {:schedules, "schedule_page", schedule_refs},
            {:summaries, "summary_page", summary_refs},
            {:rollups, "rollup_page", rollup_refs},
            {:knowledge, "knowledge_page", knowledge_refs},
            {:learning, "learning_page", learning_refs},
            {:rules, "rule_page", rule_refs},
            {:preferences, "preference_page", preference_refs},
            {:guidance, "guidance_page", guidance_refs},
            {:memory, "memory_page", memory_refs}
          ] do
        assert {:ok, first} = Projection.channel("T123", "C456", %{})
        assert {:ok, second} = Projection.channel("T123", "C456", %{key => "2"})
        first_page = Map.fetch!(first, section)
        second_page = Map.fetch!(second, section)

        assert %{total: 26, pages: 2, page: 1, key: ^key} = first_page, "#{section} first page"
        assert %{total: 26, pages: 2, page: 2, key: ^key} = second_page, "#{section} second page"
        assert length(first_page.items) == @page_size
        assert length(second_page.items) == 1

        seen = Enum.map(first_page.items ++ second_page.items, &Map.get(&1, :ref, &1[:id]))
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

  describe "continuity and learning" do
    test "a summary shows its retained state, sources and maintenance error, never its internals" do
      # The old row was an opaque continuity UUID with a thread and a date; an
      # operator could not tell what the channel remembered or why recall was
      # blocked without opening PostgreSQL.
      membership!("T123", "C456", private: false, external_shared: false)
      source = SavedEntities.source!("slack:T123:C456")

      summary =
        summary!("slack:T123", "slack:T123:C456",
          situation: "Replication is stalled on the primary",
          decisions: ["Fail over to the replica"],
          open_loops: ["Confirm the backup finished"],
          thread_ref: "1787832000.000100",
          repository_ref: "ryker",
          source_episode_id: source.episode.id,
          source_message_ref: "1787832000.000100",
          compaction_error_code: "source_capacity",
          compaction_retry_at: ~U[2026-09-11 12:00:00.000000Z],
          recall_count: 3,
          last_recalled_at: ~U[2026-09-10 13:00:00.000000Z],
          source_dependencies: [%{"secret-dependency" => "must-not-render-dependency"}]
        )

      assert {:ok, view} = Projection.channel("T123", "C456", %{})
      assert [item] = view.summaries.items
      assert item.ref == summary.ref
      assert item.title == "database"
      assert item.text == "Replication is stalled on the primary"

      assert item.groups == [
               {"Decisions", ["Fail over to the replica"]},
               {"Open work", ["Confirm the backup finished"]}
             ]

      assert item.thread_ref == "1787832000.000100"
      assert item.repository_ref == "ryker"

      assert item.request_path ==
               "/timeline/" <> URI.encode(source.episode.key, &URI.char_unreserved?/1)

      assert item.source == "https://slack.com/archives/C456/p1787832000000100"
      assert item.maintenance_error == LearningActivity.error("source_capacity")
      assert item.maintenance_retry_at == ~U[2026-09-11 12:00:00.000000Z]
      assert item.recall_count == 3
      assert item.last_recalled_at == ~U[2026-09-10 13:00:00.000000Z]
      refute Map.has_key?(item, :source_dependencies)
      refute Map.has_key?(item, :state)
      refute inspect(item) =~ "must-not-render"

      html = page("/channels/T123/C456")
      document = LazyHTML.from_document(html)
      section = LazyHTML.query(document, "#summaries")
      text = LazyHTML.text(section)
      assert text =~ "database"
      assert text =~ "Replication is stalled on the primary"
      assert text =~ "Fail over to the replica"
      assert text =~ "Confirm the backup finished"
      assert text =~ LearningActivity.error("source_capacity")
      assert text =~ "Recalled 3 times"
      assert text =~ "ryker"
      hrefs = section |> LazyHTML.query("a") |> LazyHTML.attribute("href")
      assert item.request_path in hrefs
      assert item.source in hrefs
      refute html =~ "must-not-render-dependency"
      refute html =~ String.duplicate("a", 64)
      # The ref stays reachable, but it is not the heading.
      refute section |> LazyHTML.query("h3") |> LazyHTML.text() =~ summary.ref
      assert html =~ summary.ref
    end

    test "rollups are the canonical conversation's own, unexpired ones" do
      membership!("T123", "C456", private: false, external_shared: false)
      configuration!("T123", "C456", repository_ref: "ryker")
      future = DateTime.add(@now, 30, :day)
      past = DateTime.add(@now, -30, :day)

      current =
        rollup!("slack:T123", :conversation, "slack:T123:C456",
          expires_at: future,
          source_count: 4,
          recall_count: 2,
          situation: "Rolled up situation"
        )

      rollup!("slack:T123", :conversation, "slack:T123:C456",
        expires_at: DateTime.add(past, 2, :day),
        period_start: past
      )

      rollup!("slack:T123", :repository, "ryker",
        expires_at: future,
        repository_ref: "ryker"
      )

      rollup!("slack:T123", :conversation, "slack:T123:C999", expires_at: future)
      rollup!("T123", :conversation, "slack:T123:C456", expires_at: future)
      rollup!("slack:T999", :conversation, "slack:T999:C456", expires_at: future)

      assert {:ok, view} = Projection.channel("T123", "C456", %{})
      assert view.rollups.total == 1
      assert [item] = view.rollups.items
      assert item.ref == current.ref
      assert item.source_count == 4
      assert item.recall_count == 2
      assert item.expires_at == future
      assert item.text == "Rolled up situation"
      assert %DateTime{} = item.period_start
      assert %DateTime{} = item.period_end
      refute Map.has_key?(item, :source_refs)
      refute Map.has_key?(item, :source_scopes)

      html = page("/channels/T123/C456")
      section = html |> LazyHTML.from_document() |> LazyHTML.query("#rollups") |> LazyHTML.text()
      assert section =~ "1 rollup"
      assert section =~ "4 sources"
      assert section =~ "Rolled up situation"
      assert section =~ "Recalled 2 times"
      assert section =~ "Expires 10 Oct, 12:00 UTC"
    end

    test "learned knowledge for the exact conversation shows its topic, state and history link" do
      membership!("T123", "C456", private: false, external_shared: false)
      [key] = episodes!("slack:T123:C456", 1)
      episode = Repo.get_by!(Episode, key: key)
      {_entry, _document} = KnowledgeFixtures.learn!(episode)
      knowledge!("slack:T123:C999", title: "Elsewhere", summary: "Another channel's topic")

      pruned =
        knowledge!("slack:T123:C456",
          title: "Old topic",
          summary: "must-not-render-pruned",
          retention: "pruned"
        )

      assert {:ok, view} = Projection.channel("T123", "C456", %{})
      assert view.knowledge.total == 2
      titles = Enum.map(view.knowledge.items, & &1.title)
      assert "Keep draft-ai-suggestions" in titles
      assert "Expired knowledge" in titles
      refute "Elsewhere" in titles

      learned = Enum.find(view.knowledge.items, &(&1.title == "Keep draft-ai-suggestions"))
      assert learned.available
      assert learned.version == 1
      assert learned.text =~ "wants to keep"

      assert learned.path ==
               "/memory?" <> URI.encode_query(%{"kind" => "knowledge", "item" => learned.id})

      expired = Enum.find(view.knowledge.items, &(&1.id == pruned.id))
      refute expired.available
      refute expired.text =~ "must-not-render-pruned"

      html = page("/channels/T123/C456")
      section = html |> LazyHTML.from_document() |> LazyHTML.query("#knowledge")
      assert LazyHTML.text(section) =~ "Keep draft-ai-suggestions"
      assert LazyHTML.text(section) =~ "Not used for recall"
      assert learned.path in LazyHTML.attribute(LazyHTML.query(section, "a"), "href")
      refute html =~ "must-not-render-pruned"
      refute html =~ "Elsewhere"
    end

    test "learning batches for the exact conversation show their health and link to the inspection" do
      membership!("T123", "C456", private: false, external_shared: false)

      deferred =
        batch!("slack:T123:C456",
          status: :deferred,
          error_code: "learning_judgment_deferred",
          next_attempt_at: ~U[2026-09-11 12:00:00.000000Z]
        )

      queued = batch!("slack:T123:C456", status: :queued, execution_mode: :shadow, input_count: 3)
      settled = batch!("slack:T123:C456", status: :no_change, completed_at: @now)
      batch!("slack:T123:C999", status: :queued)

      assert {:ok, view} = Projection.channel("T123", "C456", %{})
      assert view.learning.total == 3

      assert view.learning.counts == %{
               queued: 1,
               running: 0,
               applied: 0,
               no_change: 1,
               deferred: 1,
               superseded: 0
             }

      # Three batches formed in the same instant: the unique id breaks the tie.
      assert Enum.map(view.learning.items, & &1.id) ==
               Enum.sort([settled.id, queued.id, deferred.id], :desc)

      item = Enum.find(view.learning.items, &(&1.id == deferred.id))
      assert item.label == "Needs attention"
      assert item.error == LearningActivity.error("learning_judgment_deferred")
      assert item.path == LearningActivity.path(deferred.id)
      assert item.next_attempt_at == ~U[2026-09-11 12:00:00.000000Z]
      assert Enum.find(view.learning.items, &(&1.id == queued.id)).mode == :shadow
      refute Map.has_key?(item, :lease_owner)
      refute Map.has_key?(item, :policy_digest)

      html = page("/channels/T123/C456")
      section = html |> LazyHTML.from_document() |> LazyHTML.query("#learning")
      text = LazyHTML.text(section)
      assert text =~ "1 queued"
      assert text =~ "1 needs attention"
      assert text =~ "3 messages"
      assert text =~ LearningActivity.error("learning_judgment_deferred")

      assert LearningActivity.path(deferred.id) in LazyHTML.attribute(
               LazyHTML.query(section, "a"),
               "href"
             )

      refute html =~ "must-not-render-lease"
      refute html =~ "must-not-render-policy"
    end

    test "in-flight drafts and unsaved handovers are counted, never shown" do
      membership!("T123", "C456", private: false, external_shared: false)
      source = SavedEntities.source!("slack:T123:C456")
      other = SavedEntities.source!("slack:T123:C999")
      draft!(source, "must-not-render-draft")
      draft!(other, "other-draft")

      Repo.update_all(from(turn in Turn, where: turn.id == ^source.turn.id),
        set: [summary_error_code: "no_sources"]
      )

      assert {:ok, view} = Projection.channel("T123", "C456", %{})
      assert view.continuity == %{drafts: 1, handover_failures: 1}
      assert view.summaries.total == 0

      html = page("/channels/T123/C456")
      section = html |> LazyHTML.from_document() |> LazyHTML.query("#summaries")
      assert LazyHTML.text(section) =~ "1 summary draft in flight"
      assert LazyHTML.text(section) =~ "1 handover not saved"

      assert "/memory#handover-failures" in LazyHTML.attribute(
               LazyHTML.query(section, "a"),
               "href"
             )

      assert LazyHTML.text(section) =~ "No conversation summaries are retained"
      refute html =~ "must-not-render-draft"

      assert {:ok, quiet} = Projection.channel("T123", "C999", %{})
      assert quiet.continuity == %{drafts: 1, handover_failures: 0}
    end
  end

  describe "confirmed context" do
    setup do
      membership!("T123", "C456", private: false, external_shared: false)
      configuration!("T123", "C456", repository_ref: "ryker")
      # Offers need a real source turn; it lives elsewhere so it adds no episode here.
      source = SavedEntities.source!("slack:T123:CSOURCE")
      other = SavedEntities.source!("slack:T999:CSOURCE")
      %{source: source, other: other}
    end

    test "standing rules are the exact conversation's own current rules", %{source: source} do
      active = rule!(source, "Review Terraform plans", scope_ref: "slack:T123:C456")
      paused = rule!(source, "Watch deploys", scope_ref: "slack:T123:C456", status: :disabled)
      rule!(source, "Workspace rule", scope_kind: :workspace, scope_ref: "slack:T123")
      rule!(source, "Repository rule", scope_kind: :repository, scope_ref: "ryker")
      rule!(source, "Other channel", scope_ref: "slack:T123:C999")
      rule!(source, "Superseded", scope_ref: "slack:T123:C456", status: :superseded)
      rule!(source, "Deleted", scope_ref: "slack:T123:C456", status: :deleted)
      expire!(rule!(source, "Expired", scope_ref: "slack:T123:C456"))

      assert {:ok, view} = Projection.channel("T123", "C456", %{})
      assert view.rules.total == 2
      by_ref = Map.new(view.rules.items, &{&1.ref, &1})
      assert by_ref[active.ref].status == "active"
      assert by_ref[active.ref].title == "Review Terraform plans"
      assert by_ref[active.ref].trigger == "slack_message"
      assert by_ref[active.ref].library_path == "/rules#behavior-" <> active.ref
      assert by_ref[paused.ref].status == "disabled"

      html = page("/channels/T123/C456")
      section = html |> LazyHTML.from_document() |> LazyHTML.query("#rules")
      text = LazyHTML.text(section)
      assert text =~ "2 rules"
      assert text =~ "Review Terraform plans"
      assert text =~ "Paused"
      assert text =~ "Used 0 times"
      refute text =~ "Workspace rule"
      refute text =~ "Repository rule"
      refute text =~ "Other channel"
      refute text =~ "Superseded"
      refute text =~ "Expired"
      hrefs = section |> LazyHTML.query("a") |> LazyHTML.attribute("href")
      assert ("/rules#behavior-" <> active.ref) in hrefs
    end

    test "preferences and guidance apply through exact, repository and workspace scope with their labels",
         %{source: source, other: other} do
      channel = preference!(source, "response_detail", "concise", scope_ref: "slack:T123:C456")

      repository =
        preference!(source, "health_check_depth", "deep",
          scope_kind: :repository,
          scope_ref: "ryker"
        )

      workspace =
        preference!(source, "response_location", "prefer_thread",
          scope_kind: :workspace,
          scope_ref: "slack:T123"
        )

      preference!(source, "response_detail", "detailed", scope_ref: "slack:T123:C999")

      preference!(source, "health_check_depth", "quick",
        scope_kind: :repository,
        scope_ref: "other"
      )

      preference!(other, "response_detail", "detailed",
        scope_kind: :workspace,
        scope_ref: "slack:T999"
      )

      preference!(source, "health_check_depth", "quick",
        scope_ref: "slack:T123:C456",
        status: :disabled
      )

      preference!(source, "response_detail", "detailed",
        scope_kind: :operator,
        scope_ref: "slack:user:U123"
      )

      expire!(preference!(source, "health_check_depth", "standard", scope_ref: "slack:T123:C456"))

      assert {:ok, view} = Projection.channel("T123", "C456", %{})

      assert Enum.map(view.preferences.items, &{&1.ref, &1.scope}) == [
               {channel.ref, :conversation},
               {repository.ref, :repository},
               {workspace.ref, :workspace}
             ]

      # A conversation-scoped entry is always conversation- or private-visible;
      # only repository and workspace scope can be workspace-visible.
      here = guidance!(source, "Shared checklist", "conversation", scope_ref: "slack:T123:C456")

      private =
        guidance!(source, "Private note", "private",
          scope_ref: "slack:T123:C456",
          text: "Only here: must-stay-visible-here"
        )

      inherited =
        guidance!(source, "Workspace guidance", "workspace",
          scope_kind: :workspace,
          scope_ref: "slack:T123"
        )

      repository_guidance =
        guidance!(source, "Repository guidance", "workspace",
          scope_kind: :repository,
          scope_ref: "ryker"
        )

      guidance!(source, "Foreign private", "conversation",
        scope_kind: :repository,
        scope_ref: "ryker",
        source: "slack:T123:C999",
        text: "must-not-render-foreign-private"
      )

      guidance!(source, "Personal", "private",
        scope_kind: :operator,
        scope_ref: "slack:user:U123",
        text: "must-not-render-personal"
      )

      assert {:ok, view} = Projection.channel("T123", "C456", %{})

      assert Enum.map(view.guidance.items, & &1.scope) ==
               [:conversation, :conversation, :repository, :workspace]

      assert Enum.sort(Enum.map(view.guidance.items, &{&1.ref, &1.scope, &1.visibility})) ==
               Enum.sort([
                 {here.ref, :conversation, "conversation"},
                 {private.ref, :conversation, "private"},
                 {repository_guidance.ref, :repository, "workspace"},
                 {inherited.ref, :workspace, "workspace"}
               ])

      html = page("/channels/T123/C456")
      document = LazyHTML.from_document(html)
      preferences = document |> LazyHTML.query("#preferences") |> LazyHTML.text()
      assert preferences =~ "3 preferences"
      assert preferences =~ "Response detail"
      assert preferences =~ "This channel"
      assert preferences =~ "Inherited from repository ryker"
      assert preferences =~ "Inherited from the workspace"
      refute preferences =~ "Elsewhere"
      refute preferences =~ "Paused"
      refute preferences =~ "Person"
      refute preferences =~ "Stale"

      guidance = document |> LazyHTML.query("#guidance") |> LazyHTML.text()
      assert guidance =~ "4 guidance entries"
      assert guidance =~ "Only here: must-stay-visible-here"
      assert guidance =~ "Visible only in this conversation"
      refute html =~ "must-not-render-foreign-private"
      refute html =~ "must-not-render-personal"

      hrefs = document |> LazyHTML.query("#guidance a") |> LazyHTML.attribute("href")
      assert ("/guidance#behavior-" <> here.ref) in hrefs

      assert ("/preferences#behavior-" <> channel.ref) in LazyHTML.attribute(
               LazyHTML.query(document, "#preferences a"),
               "href"
             )
    end

    test "operational memory applies through its runtime scope and visibility, labeled and unaccounted",
         %{source: source} do
      channel =
        memory!(source, "primary database", "db-01",
          scope_kind: :conversation,
          scope_ref: "slack:T123:C456"
        )

      repository =
        memory!(source, "deploy dashboard", "grafana",
          scope_kind: :repository,
          scope_ref: "ryker"
        )

      workspace =
        memory!(source, "pager", "opsgenie", scope_kind: :workspace, scope_ref: "slack:T123")

      global = global_memory!("GCP project", "portal-prod")

      memory!(source, "elsewhere", "x", scope_kind: :conversation, scope_ref: "slack:T123:C999")

      memory!(source, "foreign private", "must-not-render-foreign-memory",
        scope_kind: :repository,
        scope_ref: "ryker",
        visibility: :conversation,
        source: "slack:T123:C999"
      )

      memory!(source, "other repository", "x", scope_kind: :repository, scope_ref: "other")

      memory!(source, "superseded", "x",
        scope_kind: :workspace,
        scope_ref: "slack:T123",
        status: :superseded
      )

      expire!(memory!(source, "stale", "x", scope_kind: :workspace, scope_ref: "slack:T123"))

      assert {:ok, view} = Projection.channel("T123", "C456", %{})

      assert Enum.map(view.memory.items, &{&1.ref, &1.scope}) == [
               {channel.ref, :conversation},
               {repository.ref, :repository},
               {workspace.ref, :workspace},
               {global.ref, :global}
             ]

      item = Enum.find(view.memory.items, &(&1.ref == channel.ref))
      assert item.subject == "primary database"
      assert item.value == "db-01"
      assert item.kind == :entity_relationship
      assert item.visibility == :conversation
      assert item.recall_count == 0

      html = page("/channels/T123/C456")
      section = html |> LazyHTML.from_document() |> LazyHTML.query("#memory")
      text = LazyHTML.text(section)
      assert text =~ "4 memories"
      assert text =~ "primary database"
      assert text =~ "db-01"
      assert text =~ "This channel"
      assert text =~ "Inherited from repository ryker"
      assert text =~ "Inherited from the workspace"
      assert text =~ "Every workspace"
      assert text =~ "Entity relationship"
      refute html =~ "must-not-render-foreign-memory"
      refute text =~ "elsewhere"
      refute text =~ "superseded"
      refute text =~ "stale"
      assert "/memory" in LazyHTML.attribute(LazyHTML.query(section, "a"), "href")

      # The page reads memory; only a model turn may account a recall.
      assert Repo.all(from(entry in MemoryEntry, select: entry.recall_count)) |> Enum.uniq() == [
               0
             ]

      assert Repo.all(from(behavior in Behavior, select: behavior.use_count)) |> Enum.uniq() == []
    end

    test "confirmed context is not inherited from a repository the channel does not configure",
         %{source: source} do
      Repo.delete_all(Ryker.Slack.ChannelConfiguration)

      preference!(source, "health_check_depth", "deep",
        scope_kind: :repository,
        scope_ref: "ryker"
      )

      memory!(source, "deploy dashboard", "grafana",
        scope_kind: :repository,
        scope_ref: "ryker"
      )

      assert {:ok, view} = Projection.channel("T123", "C456", %{})
      assert is_nil(view.scope.repository_ref)
      assert view.preferences.total == 0
      assert view.memory.total == 0
    end
  end

  describe "usage" do
    test "usage is the conversation's own measured ledger with explicit coverage, never a free zero" do
      # Nine executions, two without token reports and one without a price:
      # summing them as zero would have shown a cheaper channel than the
      # ledger records.
      membership!("T123", "C456", private: false, external_shared: false)
      now = DateTime.utc_now()

      execution!("slack:T123:C456",
        recorded_at: DateTime.add(now, -1, :hour),
        tokens: {100, 20, 30, 5},
        cost: "0.50"
      )

      execution!("slack:T123:C456", recorded_at: DateTime.add(now, -2, :hour), tokens: nil)

      execution!("slack:T123:C456",
        recorded_at: DateTime.add(now, -3, :hour),
        tokens: {10, 0, 2, 0},
        mode: "shadow"
      )

      execution!("slack:T123:C999",
        recorded_at: DateTime.add(now, -1, :hour),
        tokens: {1, 1, 1, 1}
      )

      assert {:ok, view} = Projection.channel("T123", "C456", %{})

      assert %{
               window: "7d",
               mode: "all",
               executions: 3,
               measured: 2,
               costed: 1,
               input_tokens: 110,
               cached_input_tokens: 20,
               output_tokens: 32,
               reasoning_tokens: 5
             } = view.usage

      assert Decimal.equal?(view.usage.cost_usd, Decimal.new("0.50"))

      %URI{path: "/activity", query: query} = URI.parse(view.usage.link)
      params = URI.decode_query(query)
      assert params["usage_channel"] == "slack:T123:C456"
      assert params["usage_window"] == "7d"
      assert params["mode"] == "all"
      assert Enum.all?(Map.keys(params), &(&1 in UsageProjection.filter_keys() or &1 == "mode"))

      assert view.usage.usage_path ==
               "/usage?" <> URI.encode_query(%{"mode" => "all", "window" => "7d"})

      assert {:ok, live} = Projection.channel("T123", "C456", %{"mode" => "live"})
      assert %{executions: 2, measured: 1, costed: 1, mode: "live"} = live.usage
      assert URI.decode_query(URI.parse(live.usage.link).query)["mode"] == "live"
      assert {:ok, shadow} = Projection.channel("T123", "C456", %{"mode" => "shadow"})
      assert %{executions: 1, measured: 1, costed: 0, mode: "shadow"} = shadow.usage

      html = page("/channels/T123/C456")
      section = html |> LazyHTML.from_document() |> LazyHTML.query("#usage")
      text = section |> LazyHTML.text() |> String.replace(~r/\s+/, " ")
      assert text =~ "Last 7 days"
      assert text =~ "all work"
      assert text =~ "3 executions"
      assert text =~ "2 of 3 reported tokens"
      assert text =~ "1 of 3 recorded a cost"
      assert text =~ "$0.50"
      assert text =~ "110"
      hrefs = section |> LazyHTML.query("a") |> LazyHTML.attribute("href")
      assert view.usage.link in hrefs
      assert view.usage.usage_path in hrefs
    end

    test "measured zero, missing measurement and missing cost read differently" do
      membership!("T123", "C456", private: false, external_shared: false)
      now = DateTime.utc_now()

      quiet = page("/channels/T123/C456") |> usage_text()
      assert quiet =~ "No executions"
      refute quiet =~ "$0"
      refute quiet =~ "Not recorded"

      execution!("slack:T123:C456",
        recorded_at: DateTime.add(now, -1, :hour),
        tokens: {0, 0, 0, 0}
      )

      assert {:ok, view} = Projection.channel("T123", "C456", %{})
      assert %{executions: 1, measured: 1, costed: 0, input_tokens: 0, cost_usd: nil} = view.usage
      measured_zero = page("/channels/T123/C456") |> usage_text()
      assert measured_zero =~ "1 of 1 reported tokens"
      assert measured_zero =~ "0 input"
      assert measured_zero =~ "Cost Not recorded"
      refute measured_zero =~ "$0"

      Repo.delete_all(Execution)
      execution!("slack:T123:C456", recorded_at: DateTime.add(now, -1, :hour), tokens: nil)
      assert {:ok, view} = Projection.channel("T123", "C456", %{})
      assert %{executions: 1, measured: 0, costed: 0} = view.usage
      missing = page("/channels/T123/C456") |> usage_text()
      assert missing =~ "0 of 1 reported tokens"
      assert missing =~ "Tokens Not recorded"
      assert missing =~ "Cost Not recorded"
      refute missing =~ "0 input"
    end

    test "the window is explicit and its boundaries hold for every choice" do
      membership!("T123", "C456", private: false, external_shared: false)
      now = DateTime.utc_now()

      for hours <- [1, 72, 480, 1440] do
        execution!("slack:T123:C456",
          recorded_at: DateTime.add(now, -hours, :hour),
          tokens: {1, 0, 0, 0}
        )
      end

      for {window, expected, label} <- [
            {"24h", 1, "Last 24 hours"},
            {"7d", 2, "Last 7 days"},
            {"30d", 3, "Last 30 days"},
            {"all", 4, "All time"},
            {"yesterday", 2, "Last 7 days"}
          ] do
        assert {:ok, view} = Projection.channel("T123", "C456", %{"usage_window" => window})
        assert view.usage.executions == expected, "#{window} counted #{view.usage.executions}"

        assert URI.decode_query(URI.parse(view.usage.link).query)["usage_window"] ==
                 view.usage.window

        assert page("/channels/T123/C456?usage_window=#{window}") |> usage_text() =~ label
      end

      # The pager links keep the chosen window, and the window keeps the pages.
      for _ <- 1..26, do: summary!("slack:T123", "slack:T123:C456", [])
      html = page("/channels/T123/C456?usage_window=24h&summary_page=2&mode=live")
      document = LazyHTML.from_document(html)

      [previous] =
        document |> LazyHTML.query("#summaries .pagination a") |> LazyHTML.attribute("href")

      assert previous == "/channels/T123/C456?mode=live&usage_window=24h#summaries"

      assert document |> LazyHTML.query("#summaries .pagination span") |> LazyHTML.text() =~
               "Page 2 of 2"

      assert usage_text(html) =~ "Last 24 hours"
      assert usage_text(html) =~ "live work"
    end

    defp usage_text(html) do
      html
      |> LazyHTML.from_document()
      |> LazyHTML.query("#usage")
      |> LazyHTML.text()
      |> String.replace(~r/\s+/, " ")
    end
  end

  describe "live routing" do
    setup do
      start_supervised!(
        {Endpoint,
         [
           server: false,
           secret_key_base: String.duplicate("s", 64),
           pubsub_server: Ryker.ControlPlane.PubSub,
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

  defp continuity_state(attributes, sequence) do
    %{
      "active_topics" => ["database"],
      "decisions" => Map.get(attributes, :decisions, []),
      "evidence_refs" => [],
      "goal" => "Restore the primary",
      "open_loops" => Map.get(attributes, :open_loops, []),
      "participants" => ["U1"],
      "purpose" => "Incident response",
      "situation" => Map.get(attributes, :situation, "Situation #{sequence}"),
      "topology" => [],
      "unresolved_questions" => []
    }
  end

  defp summary!(workspace, conversation, attributes) do
    attributes = Map.new(attributes)
    sequence = System.unique_integer([:positive, :monotonic])

    Repo.insert!(%ConversationSummary{
      id: Ecto.UUID.generate(),
      ref: "summary:#{sequence}",
      identity_key: Ryker.CanonicalJSON.digest("identity:#{sequence}"),
      transport: "slack",
      workspace_ref: workspace,
      conversation_ref: conversation,
      thread_ref: Map.get(attributes, :thread_ref),
      repository_ref: Map.get(attributes, :repository_ref),
      visibility: :conversation,
      state: continuity_state(attributes, sequence),
      source_dependencies: Map.get(attributes, :source_dependencies, []),
      state_fingerprint: String.duplicate("a", 64),
      source_episode_id: Map.get(attributes, :source_episode_id),
      source_message_ref: Map.get(attributes, :source_message_ref),
      source_result_ref: "result:#{sequence}",
      compaction_error_code: Map.get(attributes, :compaction_error_code),
      compaction_retry_at: Map.get(attributes, :compaction_retry_at),
      recall_count: Map.get(attributes, :recall_count, 0),
      last_recalled_at: Map.get(attributes, :last_recalled_at),
      inserted_at: Map.get(attributes, :updated_at, @now),
      updated_at: Map.get(attributes, :updated_at, @now)
    })
  end

  defp rollup!(workspace, scope_kind, scope_ref, attributes) do
    attributes = Map.new(attributes)
    sequence = System.unique_integer([:positive, :monotonic])
    period_start = Map.get(attributes, :period_start, DateTime.add(@now, -2, :day))

    Repo.insert!(%ConversationRollup{
      id: Ecto.UUID.generate(),
      ref: "rollup:#{sequence}",
      workspace_ref: workspace,
      scope_kind: scope_kind,
      scope_ref: scope_ref,
      repository_ref: Map.get(attributes, :repository_ref),
      visibility: if(scope_kind == :repository, do: :public, else: :conversation),
      period_start: period_start,
      period_end: DateTime.add(period_start, 1, :day),
      state: continuity_state(attributes, sequence),
      source_dependencies: Map.get(attributes, :source_dependencies, []),
      state_fingerprint: String.duplicate("b", 64),
      source_refs: Map.get(attributes, :source_refs, ["summary:#{sequence}"]),
      source_scopes: [
        %{"transport" => "slack", "workspace_ref" => "T123", "channel_ref" => "C456"}
      ],
      source_count: Map.get(attributes, :source_count, 1),
      expires_at: Map.fetch!(attributes, :expires_at),
      recall_count: Map.get(attributes, :recall_count, 0),
      inserted_at: @now,
      updated_at: @now
    })
  end

  defp knowledge!(conversation, attributes) do
    attributes = Map.new(attributes)
    sequence = System.unique_integer([:positive, :monotonic])
    workspace = conversation |> String.split(":", parts: 3) |> Enum.take(2) |> Enum.join(":")

    state =
      %{
        "title" => Map.fetch!(attributes, :title),
        "summary" => Map.get(attributes, :summary, "Summary #{sequence}")
      }
      |> then(fn state ->
        case Map.get(attributes, :retention) do
          nil -> state
          retention -> Map.put(state, "retention", retention)
        end
      end)

    Repo.insert!(%ConversationKnowledge{
      id: Ecto.UUID.generate(),
      scope_key: Ryker.CanonicalJSON.digest(conversation),
      topic_key: "topic-#{sequence}",
      transport: "slack",
      workspace_ref: workspace,
      conversation_ref: conversation,
      visibility: :conversation,
      state: state,
      version: 1,
      source_generation: 1,
      source_dependencies: Map.get(attributes, :source_dependencies, []),
      source_input_id: Ecto.UUID.generate(),
      latest_source_at: @now,
      inserted_at: @now,
      updated_at: @now
    })
  end

  defp batch!(conversation, attributes) do
    attributes = Map.new(attributes)
    status = Map.fetch!(attributes, :status)

    Repo.insert!(%Batch{
      scope_key: Ryker.CanonicalJSON.digest(conversation),
      transport: "slack",
      conversation_ref: conversation,
      execution_mode: Map.get(attributes, :execution_mode, :live),
      policy: "learning-policy",
      policy_digest: "must-not-render-policy",
      status: status,
      input_count: Map.get(attributes, :input_count, 1),
      lease_ref: if(status == :running, do: Ecto.UUID.generate()),
      lease_owner: if(status == :running, do: "must-not-render-lease"),
      lease_expires_at: if(status == :running, do: DateTime.add(@now, 1, :hour)),
      next_attempt_at: Map.get(attributes, :next_attempt_at),
      error_code: Map.get(attributes, :error_code),
      completed_at: Map.get(attributes, :completed_at),
      inserted_at: @now,
      updated_at: @now
    })
  end

  # Offers are validated by their record contract; the stored payload is what
  # the runtime and the page read. Keep the two apart so a page test can hold
  # a stored key the contract would never accept (26 distinct preferences).
  defp rule!(source, title, overrides) do
    payload = %{
      "context_channel" => "slack:T123:C456",
      "delivery_channel" => "slack:T123:C456",
      "expires_at" => nil,
      "filter" => %{"event" => "terraform_plan", "title" => title},
      "hold" => nil,
      "repository" => nil,
      "source_kind" => "slack_message",
      "task" => "Review #{title}.",
      "title" => title
    }

    behavior!(source, :standing_assignment, payload, payload, overrides)
  end

  defp preference!(source, key, value, overrides) do
    scope_kind = Keyword.get(overrides, :scope_kind, :conversation)

    offer = %{
      "expires_in" => "30d",
      "key" => "health_check_depth",
      "repository" => if(scope_kind == :repository, do: Keyword.fetch!(overrides, :scope_ref)),
      "scope" => Atom.to_string(scope_kind),
      "value" => "deep"
    }

    behavior!(source, :preference, offer, %{"key" => key, "value" => value}, overrides)
  end

  defp guidance!(source, subject, visibility, overrides) do
    scope_kind = Keyword.get(overrides, :scope_kind, :conversation)

    offer = %{
      "expires_in" => "30d",
      "repository" => if(scope_kind == :repository, do: Keyword.fetch!(overrides, :scope_ref)),
      "scope" => Atom.to_string(scope_kind),
      "subject" => subject,
      "summary" => "Summary of #{subject}",
      "text" => Keyword.get(overrides, :text, "Full text of #{subject}."),
      "visibility" => visibility
    }

    behavior!(
      source,
      :guidance,
      offer,
      Map.merge(offer, Keyword.get(overrides, :extra, %{})),
      overrides
    )
  end

  defp behavior!(source, kind, offer, payload, overrides) do
    {:ok, record} =
      Records.create(
        Records.token(source.turn),
        "offer:#{Ecto.UUID.generate()}",
        "#{kind}_offer",
        offer
      )

    id = Ecto.UUID.generate()

    Repo.insert!(%Behavior{
      id: id,
      ref: "behavior:#{id}",
      offer_record_id: record.id,
      kind: kind,
      status: Keyword.get(overrides, :status, :active),
      workspace_ref: workspace_of(source.conversation_ref),
      scope_kind: Keyword.get(overrides, :scope_kind, :conversation),
      scope_ref: Keyword.fetch!(overrides, :scope_ref),
      identity_key: payload["subject"] || payload["key"] || payload["title"] || payload["task"],
      payload: payload,
      confirmed_by_actor_ref: "slack:user:U123",
      confirmation_ref: "interaction:#{id}",
      confirmed_at: @now,
      source_transport: "slack",
      source_conversation_ref: confirmed_in(source, overrides),
      source_thread_ref: "1.000001",
      source_message_ref: "1.000002",
      expires_at: DateTime.add(@now, 30, :day),
      inserted_at: @now,
      updated_at: @now
    })
  end

  # A conversation-scoped entry is confirmed in the conversation it scopes;
  # wider scopes were confirmed wherever the offer's source turn ran.
  defp confirmed_in(source, overrides) do
    Keyword.get_lazy(overrides, :source, fn ->
      if Keyword.get(overrides, :scope_kind, :conversation) == :conversation,
        do: Keyword.fetch!(overrides, :scope_ref),
        else: source.conversation_ref
    end)
  end

  defp memory!(source, subject, value, overrides) do
    scope_kind = Keyword.fetch!(overrides, :scope_kind)
    scope_ref = Keyword.fetch!(overrides, :scope_ref)

    visibility =
      Keyword.get(
        overrides,
        :visibility,
        if(scope_kind == :conversation, do: :conversation, else: :workspace)
      )

    payload = %{
      "expires_in" => "30d",
      "kind" => "entity_relationship",
      "repository" => if(scope_kind == :repository, do: scope_ref),
      "scope" => Atom.to_string(scope_kind),
      "subject" => subject,
      "value" => value,
      "visibility" => Atom.to_string(visibility)
    }

    {:ok, record} =
      Records.create(
        Records.token(source.turn),
        "offer:#{Ecto.UUID.generate()}",
        "memory_offer",
        payload
      )

    id = Ecto.UUID.generate()

    Repo.insert!(%MemoryEntry{
      id: id,
      ref: "memory:#{id}",
      offer_record_id: record.id,
      kind: :entity_relationship,
      status: Keyword.get(overrides, :status, :active),
      workspace_ref: "slack:T123",
      scope_kind: scope_kind,
      scope_ref: scope_ref,
      visibility: visibility,
      subject: subject,
      payload: payload,
      payload_fingerprint: Ryker.CanonicalJSON.digest(payload),
      confirmed_by_actor_ref: "slack:user:U123",
      confirmation_ref: "interaction:#{id}",
      confirmed_at: @now,
      source_transport: "slack",
      source_conversation_ref: confirmed_in(source, overrides),
      source_thread_ref: "1.000001",
      source_message_ref: "1.000002",
      expires_at: DateTime.add(@now, 30, :day),
      inserted_at: @now,
      updated_at: @now
    })
  end

  defp workspace_of("slack:" <> rest),
    do: "slack:" <> (rest |> String.split(":", parts: 2) |> hd())

  defp global_memory!(subject, value) do
    id = Ecto.UUID.generate()

    payload = %{
      "kind" => "entity_relationship",
      "scope" => "global",
      "subject" => subject,
      "value" => value,
      "visibility" => "global"
    }

    Repo.insert!(%MemoryEntry{
      id: id,
      ref: "memory:#{id}",
      kind: :entity_relationship,
      status: :active,
      workspace_ref: "installation",
      scope_ref: "installation:" <> Ryker.CanonicalJSON.digest(subject),
      scope_kind: :global,
      visibility: :global,
      subject: subject,
      payload: payload,
      payload_fingerprint: Ryker.CanonicalJSON.digest(payload),
      answer_provenance: %{"record_ref" => "answer:#{id}"},
      confirmed_by_actor_ref: "slack:user:U123",
      confirmation_ref: "answer:#{id}",
      confirmed_at: @now,
      source_transport: "slack",
      source_conversation_ref: "slack:T123:C456",
      source_thread_ref: "1.000001",
      source_message_ref: "1.000002",
      expires_at: nil,
      inserted_at: @now,
      updated_at: @now
    })
  end

  # Expiry is a read-time rule: the stored status still says active. The
  # fixture clock sits in the past, so an hour after confirmation is already
  # expired today while still satisfying "expires after confirmed".
  defp expire!(%Behavior{id: id} = behavior) do
    Repo.update_all(from(row in Behavior, where: row.id == ^id),
      set: [expires_at: DateTime.add(@now, 1, :hour)]
    )

    behavior
  end

  defp expire!(%MemoryEntry{id: id} = entry) do
    Repo.update_all(from(row in MemoryEntry, where: row.id == ^id),
      set: [expires_at: DateTime.add(@now, 1, :hour)]
    )

    entry
  end

  defp execution!(conversation, options) do
    tokens = Keyword.get(options, :tokens)

    {input, cached, output, reasoning} =
      case tokens do
        {input, cached, output, reasoning} -> {input, cached, output, reasoning}
        nil -> {nil, nil, nil, nil}
      end

    cost = Keyword.get(options, :cost)

    Repo.insert!(%Execution{
      kind: "work",
      source_id: Ecto.UUID.generate(),
      generation: "1",
      transport: "slack",
      conversation_ref: conversation,
      execution_mode: Keyword.get(options, :mode, "live"),
      status: "completed",
      execution_target: "unpriced:model/none@none",
      usage_recorded: not is_nil(tokens),
      usage_input_tokens: input,
      usage_cached_input_tokens: cached,
      usage_output_tokens: output,
      usage_reasoning_tokens: reasoning,
      usage_cost_recorded: not is_nil(cost),
      usage_cost_usd: cost && Decimal.new(cost),
      recorded_at: Keyword.fetch!(options, :recorded_at)
    })
  end

  defp draft!(source, marker) do
    Repo.insert!(%ConversationSummaryDraft{
      id: Ecto.UUID.generate(),
      episode_id: source.episode.id,
      turn_id: source.turn.id,
      state: %{"situation" => marker},
      state_fingerprint: String.duplicate("d", 64)
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
      repository_ref: "ryker",
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
