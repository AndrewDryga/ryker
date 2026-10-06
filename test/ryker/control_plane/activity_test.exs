defmodule Ryker.ControlPlane.ActivityTest do
  use Ryker.DataCase, async: false
  import Ecto.Query
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{Actions, Activity, ActivityPage, EpisodeProjection}
  alias Ryker.ControlPlane.{OverviewProjection, UsagePage, UsageProjection, WorkspaceProjection}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Answers
  alias Ryker.Fixtures.Episodes, as: Fixtures
  alias Ryker.Fixtures.SavedEntities
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Operator.FailureDismissals
  alias Ryker.Repo
  alias Ryker.Schedules.ScheduleOccurrenceChangeset
  alias Ryker.Slack.Input
  alias Ryker.Slack.Names
  alias Ryker.Work.Custody
  alias Ryker.Work.Session
  alias Ryker.Work.Turn

  test "a request title names the people and channels it mentions, never their raw ids" do
    # The first Slack episode after the rename was headed "<@U0BL8MNPUSY> post-rename
    # check…": the title is the message's text, and nothing resolved its mention
    # tokens even though the body below it rendered "@Emisar". A title is plain
    # text, so the directory's name replaces the token outright.
    parent = self()

    start_supervised!(
      {Names,
       workspace: "T123",
       fetch: fn ref ->
         send(parent, {:lookup, ref})
         {:ok, if(String.starts_with?(ref, "U"), do: "emisar", else: "test")}
       end}
    )

    Names.name("T123", "U1")
    Names.name("T123", "C456")
    assert :ok = GenServer.call(Names, :refresh)
    assert :ok = GenServer.call(Names, :refresh)

    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "U2"},
        channel_ref: "C456",
        content: %{"text" => "<@U1> is <#C456> healthy?"},
        event_kind: :message,
        event_ref: "Ev-mention-title",
        message_ref: "1788370103.362810",
        occurred_at: DateTime.utc_now(),
        revision: 1,
        thread_ref: nil,
        workspace_ref: "T123"
      })

    {:ok, _} = Inbox.record(input)
    assert %{items: [%{title: "@emisar is #test healthy?"}]} = Activity.list(%{})
  end

  test "an episode reads as the name Work gave it" do
    # Rows showed each episode's first message; a named episode shows its name.
    {:ok, %{episode: episode}} = Episodes.apply(Fixtures.admit_input())

    {1, _} =
      Repo.update_all(
        from(digest in Ryker.Episodes.RoutingDigest, where: digest.episode_id == ^episode.id),
        set: [
          title: "Investigate checkout 502s",
          title_turn_id: Ecto.UUID.generate(),
          title_updated_at: DateTime.utc_now()
        ]
      )

    assert Activity.request_titles([episode.key])[episode.key].title ==
             "Investigate checkout 502s"

    assert Enum.any?(Activity.list(%{}).items, &(&1.title == "Investigate checkout 502s"))
  end

  test "attachment-only Slack notifications keep readable searchable request titles" do
    # Most replay rows said source unavailable although Slack retained the alert
    # in attachments. This fallback is harvested from the blocked HCP notification.
    title = "Run run-Ko2xq6dNyoefZfUX"

    {:ok, input} =
      Input.new(%{
        actor: %{kind: :bot, ref: "B0TENANTBT1"},
        channel_ref: "C456",
        content: %{"text" => "", "attachments" => [%{"fallback" => title}]},
        event_kind: :message,
        event_ref: "Ev-attachment-title",
        message_ref: "1788370103.362809",
        occurred_at: DateTime.utc_now(),
        revision: 1,
        thread_ref: nil,
        workspace_ref: "T123"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)
    assert %{items: [%{title: ^title}]} = Activity.list(%{})
    assert Activity.list(%{"q" => "Ko2xq6dNyoefZfUX"}).total == 1

    {:ok, %{episode: episode}} = Episodes.apply(Fixtures.admit_input())

    Repo.update_all(from(e in Entry, where: e.id == ^entry.id),
      set: [
        episode_id: episode.id,
        status: :decided,
        decision_action: :start_episode,
        decision_ref: "decision:attachment-title",
        decision_fingerprint: String.duplicate("a", 64),
        decision_document: %{"action" => "start_episode", "episode_ref" => episode.key}
      ]
    )

    assert Activity.request_titles([episode.key])[episode.key].title == title

    Repo.update_all(from(e in Entry, where: e.id == ^entry.id),
      set: [operational_pruned_at: DateTime.utc_now()]
    )

    assert Activity.list(%{"q" => "Ko2xq6dNyoefZfUX"}).total == 0
  end

  test "usage drilldowns retain measured admission requests that never created an episode" do
    # Admission spend was visible in Usage but its request vanished on every drilldown.
    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "U123"},
        channel_ref: "C456",
        content: %{"text" => "Inspect the slow admission request"},
        event_kind: :message,
        event_ref: "Ev-usage-admission",
        message_ref: "1787832099.000100",
        occurred_at: DateTime.utc_now(),
        revision: 1,
        thread_ref: nil,
        workspace_ref: "T123"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)

    Repo.insert!(%Ryker.Accounting.Execution{
      kind: "admission",
      source_id: entry.id,
      generation: "1",
      transport: entry.destination_transport,
      conversation_ref: entry.destination_conversation_ref,
      execution_mode: "live",
      remote_ref: "usage-admission",
      status: "completed",
      execution_target: "codex:gpt-5.6-luna/low@emisar",
      usage_recorded: true,
      usage_input_tokens: 10,
      recorded_at: DateTime.utc_now()
    })

    assert UsageProjection.page(%{}).totals.attempts == 1

    for params <- [
          %{"usage_profile" => "emisar"},
          %{"usage_work_kind" => "admission"},
          %{"usage_actor" => "U123", "usage_workspace" => "T123"}
        ] do
      assert %{total: 1, items: [%{kind: "admission", id: id}]} = Activity.list(params)
      assert id == entry.id
    end

    assert Activity.list(%{"usage_profile" => "personal"}).total == 0
    assert Activity.list(%{"usage_profile" => "emisar", "mode" => %{"bad" => "value"}}).total == 1
  end

  test "activity shows the actual request before admission and follows its durable episode" do
    # The previous dashboard hid both queued requests and every human-readable title.
    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "U123"},
        channel_ref: "C456",
        content: %{"text" => "Inspect the slow admission request"},
        event_kind: :message,
        event_ref: "Ev-activity",
        message_ref: "1787832099.000100",
        occurred_at: DateTime.utc_now(),
        revision: 1,
        thread_ref: nil,
        workspace_ref: "T123"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)
    assert %{items: [item], total: 1} = Activity.list(%{})
    assert item.title == "Inspect the slow admission request"
    assert item.state == "pending"
    assert item.href == "/timeline/#{entry.id}"
    assert item.bucket == "running"
    assert item.conversation == "slack:T123:C456"
    assert Activity.list(%{"q" => "slow admission"}).total == 1
    assert Activity.list(%{"q" => "%_"}).total == 0

    {:ok, %{episode: episode}} = Episodes.apply(Fixtures.admit_input())

    Repo.update_all(from(e in Entry, where: e.id == ^entry.id),
      set: [
        episode_id: episode.id,
        status: :decided,
        decision_action: :start_episode,
        decision_ref: "decision:activity",
        decision_fingerprint: String.duplicate("a", 64),
        decision_document: %{"action" => "start_episode", "episode_ref" => episode.key}
      ]
    )

    assert %{items: [item], total: 1} = Activity.list(%{})
    assert item.title == "Inspect the slow admission request"
    assert item.href == "/timeline/#{episode.id}"

    assert %{title: "Inspect the slow admission request"} =
             Activity.request_titles([episode.key])[episode.key]

    {:ok, _session} = Custody.pin_episode(episode.id, "label-test", String.duplicate("a", 64))

    # Direct conversation work has a worker session but no repository checkout.
    assert WorkspaceProjection.copies(%{}).current == []

    # The native list shows source text; moving off the metadata-only listing
    # must retain HTML escaping and never surface credentials or raw artifacts.
    Repo.update_all(from(e in Entry, where: e.id == ^entry.id),
      set: [
        content: %{
          "text" => "Investigate <script>steal()</script> token=ghp_abcdefghijklmnopqrstuvwxyz",
          "internal_artifact" => "raw-secret-value"
        }
      ]
    )

    activity = Activity.list(%{})
    [item] = activity.items
    refute inspect(item) =~ "ghp_abcdefghijklmnopqrstuvwxyz"
    refute inspect(item) =~ "raw-secret-value"
    refute Map.has_key?(item, :content)

    html =
      render_component(&ActivityPage.render/1,
        activity: activity,
        fleet: %{required: false},
        params: %{},
        path: "/activity",
        now: DateTime.utc_now(),
        stream: [{"request-#{item.id}", item}],
        new_items: 0,
        schedules: []
      )

    assert html =~ "Investigate &lt;script&gt;"
    refute html =~ "<script>steal()"
    refute html =~ "ghp_abcdefghijklmnopqrstuvwxyz"
    refute html =~ "raw-secret-value"
  end

  test "native activity paging and state filters stay bounded on malformed query values" do
    {:ok, %{episode: episode}} = Episodes.apply(Fixtures.admit_input(%{episode_key: "paging"}))

    for value <- [nil, "0", "-1", "not-a-number", %{"nested" => "1"}, [], "100000000000000000000"] do
      assert %{page: 1, pages: 1, total: 1, items: [item]} = Activity.list(%{"page" => value})
      assert item.id == episode.id
    end

    for state <- ~w(complete cancelled waiting_for_event) do
      assert %{items: [], total: 0, searchable: true} = Activity.list(%{"state" => state})
    end

    assert %{items: [item]} = Activity.list(%{"state" => "working", "q" => "paging"})
    assert item.id == episode.id
    assert item.href == "/timeline/" <> episode.id

    # The native search keeps its own 200-character bound, not the removed
    # listing's behavior of silently ignoring any query over 120 bytes.
    assert %{items: [], total: 0} = Activity.list(%{"q" => String.duplicate("x", 1_000)})
    assert %{total: 1} = Activity.list(%{"q" => %{"nested" => "value"}})
  end

  test "conversation history includes every page without requiring usage measurements" do
    # The Lab rail stopped at twenty episodes and Slack had no conversation view.
    for index <- 1..32 do
      {:ok, _} =
        Episodes.apply(
          Fixtures.admit_input(%{
            episode_id: Ecto.UUID.generate(),
            episode_key: "conversation:#{index}",
            native_input_id: "conversation:#{index}",
            turn_ref: "conversation-turn:#{index}",
            destination: %{
              conversation_ref: "slack:T123:C-history",
              thread_ref: if(index == 32, do: "another-thread", else: "thread-one"),
              transport: "slack"
            }
          })
        )
    end

    {:ok, _} = Episodes.apply(Fixtures.admit_input())
    params = %{"conversation" => "slack:T123:C-history", "transport" => "slack", "mode" => "all"}
    assert %{total: 32, pages: 2, items: first} = Activity.list(params)
    assert length(first) == 30
    assert %{total: 32, page: 2, items: second} = Activity.list(Map.put(params, "page", "2"))
    assert length(second) == 2
    assert length(Enum.uniq_by(first ++ second, & &1.id)) == 32
    assert Activity.list(Map.put(params, "thread", "thread-one")).total == 31
    assert Activity.list(Map.put(params, "conversation", "slack:T123:C-other")).total == 0
    assert Activity.list(Map.put(params, "transport", "control_plane")).total == 0

    assert Enum.any?(
             Activity.conversation_filter_options(),
             &(&1.conversation_ref == params["conversation"])
           )
  end

  test "chats with the same title are told apart by a time that names its zone, newest first" do
    # QA re-test, 2026-09-26: Activity › Filter › Conversation listed four
    # "Checkout readiness alert and 08:00 deploy" chats with nothing to tell
    # them apart. The time added to tell them apart then read "26 Sep, 11:33"
    # beside rows that say "11:33 UTC" (QA P3, the same day): a clock time on
    # Activity says which zone it is in.
    for {chat, at} <- [
          {"chat-a", ~U[2026-09-24 09:15:00.000000Z]},
          {"chat-b", ~U[2026-09-25 14:02:00.000000Z]}
        ] do
      id = Ecto.UUID.generate()

      {:ok, _} =
        Episodes.apply(
          Fixtures.admit_input(%{
            episode_id: id,
            episode_key: "conversation:#{chat}",
            native_input_id: "conversation:#{chat}",
            turn_ref: "conversation-turn:#{chat}",
            destination: %{conversation_ref: chat, thread_ref: nil, transport: "control_plane"}
          })
        )

      Repo.update_all(from(e in Ryker.Episodes.Episode, where: e.id == ^id),
        set: [updated_at: at]
      )
    end

    assert Activity.conversation_filter_options()
           |> Enum.filter(&(&1.source == "control_plane"))
           |> Enum.map(&{&1.conversation_ref, &1.conversation_label}) == [
             {"chat-b",
              "Direct conversation · Message text no longer available · 25 Sep, 14:02 UTC"},
             {"chat-a",
              "Direct conversation · Message text no longer available · 24 Sep, 09:15 UTC"}
           ]
  end

  # The filter kept 500 conversations in alphabetical order, so past 500 the
  # newest could be missing from it while older ones stayed (2026-10-04
  # review). It keeps the 500 most recently active.
  test "the conversation filter keeps the most recently active conversations" do
    for index <- 0..500 do
      chat =
        if index == 500, do: "chat-zzz", else: "chat-#{String.pad_leading("#{index}", 3, "0")}"

      id = Ecto.UUID.generate()

      {:ok, _} =
        Episodes.apply(
          Fixtures.admit_input(%{
            episode_id: id,
            episode_key: "conversation:#{chat}",
            native_input_id: "conversation:#{chat}",
            turn_ref: "conversation-turn:#{chat}",
            destination: %{conversation_ref: chat, thread_ref: nil, transport: "control_plane"}
          })
        )

      Repo.update_all(from(e in Ryker.Episodes.Episode, where: e.id == ^id),
        set: [updated_at: DateTime.add(~U[2026-09-24 09:00:00.000000Z], index, :minute)]
      )
    end

    options = Activity.conversation_filter_options()
    assert length(options) == 500
    assert hd(options).conversation_ref == "chat-zzz"
    refute Enum.any?(options, &(&1.conversation_ref == "chat-000"))
  end

  test "activity uses human fallback labels and never passes secrets or shadow traffic as live" do
    {:ok, %{episode: episode}} = Episodes.apply(Fixtures.admit_input())
    assert %{items: [item]} = Activity.list(%{})
    # Where it came from is the row's own fact; the title said it twice for a
    # direct conversation ("Direct conversation conversation · ...").
    assert item.title == "Message text no longer available"
    assert item.source == "Slack"
    refute item.title =~ episode.key

    Repo.update_all(from(e in Ryker.Episodes.Episode, where: e.id == ^episode.id),
      set: [execution_mode: :shadow]
    )

    assert Activity.list(%{}).total == 0
    assert Activity.list(%{"mode" => "shadow"}).total == 1
    assert Activity.list(%{"mode" => "all"}).total == 1
  end

  test "Usage drill-downs retain shadow and all execution modes" do
    for mode <- ~w(shadow all) do
      snapshot = UsageProjection.page(%{"mode" => mode})
      measurements = %{attempts: 1, measured: 0, tokens: 0, costed: 0, cost_usd: nil}

      snapshot = %{
        snapshot
        | targets: [
            Map.merge(measurements, %{
              target: "sol/medium",
              provider: "codex",
              model: "sol",
              effort: "medium"
            })
          ],
          channels: [Map.merge(measurements, %{transport: "slack", conversation_ref: "C123"})],
          repositories: [Map.put(measurements, :repository_ref, "emisar")]
      }

      html =
        snapshot
        |> Map.put(:models, snapshot.targets)
        |> UsagePage.render()
        |> IO.iodata_to_binary()

      links =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("a[href^='/activity?']")
        |> LazyHTML.attribute("href")

      assert length(links) == 3
      assert Enum.all?(links, &(URI.decode_query(URI.parse(&1).query)["mode"] == mode))
    end
  end

  test "usage drill-down filters preserve episode identity and repository" do
    # Replacing the episode directory must not turn cost drill-downs into unrelated activity.
    {:ok, %{episode: episode}} = Episodes.apply(Fixtures.admit_input())

    {:ok, session} =
      Custody.pin_episode(episode.id, "activity-test", String.duplicate("a", 64))

    assert {:ok, _claim} = Custody.claim_next("activity-test", 60, :work)

    Repo.update_all(from(s in Session, where: s.id == ^session.id),
      set: [repository_ref: "repo:emisar"]
    )

    assert {1, _} =
             Repo.update_all(from(t in Turn, where: t.episode_id == ^episode.id),
               set: [execution_target: "sol/medium"]
             )

    assert Activity.list(%{"q" => episode.key}).total == 1
    assert Activity.list(%{"q" => episode.destination_conversation_ref}).total == 1
    assert Activity.list(%{"repository" => "repo:emisar"}).total == 1
    assert Activity.list(%{"repository" => "repo:other"}).total == 0
    assert Activity.list(%{"state" => "complete"}).total == 0
    assert Activity.list(%{"state" => to_string(episode.state)}).total == 1
  end

  test "long case files show the latest messages while preserving the original request title" do
    # The old trace silently displayed messages 181–200 as the latest twenty forever.
    {:ok, %{episode: episode}} = Episodes.apply(Fixtures.admit_input())

    for index <- 1..205 do
      {:ok, input} =
        Input.new(%{
          actor: %{kind: :user, ref: "U123"},
          channel_ref: "C456",
          content: %{"text" => "Request message #{index}"},
          event_kind: :message,
          event_ref: "Ev-long-case-#{index}",
          message_ref: "1787832099.#{String.pad_leading(to_string(index), 6, "0")}",
          occurred_at: DateTime.add(~U[2026-08-28 12:00:00.000000Z], index),
          revision: 1,
          thread_ref: nil,
          workspace_ref: "T123"
        })

      {:ok, %{entry: entry}} = Inbox.record(input)

      Repo.update_all(from(e in Entry, where: e.id == ^entry.id),
        set: [
          episode_id: episode.id,
          status: :decided,
          decision_action: :continue_episode,
          decision_ref: "decision:long-case:#{index}",
          decision_fingerprint: String.duplicate("a", 64),
          decision_document: %{"action" => "continue_episode", "episode_ref" => episode.key}
        ]
      )
    end

    {:ok, detail} = EpisodeProjection.fetch(episode.key)
    assert detail.trace.case_file.title == "Request message 1"
    assert length(detail.trace.case_file.messages) == 20
    assert List.first(detail.trace.case_file.messages).text == "Request message 186"
    assert List.last(detail.trace.case_file.messages).text == "Request message 205"
  end

  test "search finds a request by the repository its work used, and the row names it" do
    # QA, 2026-09-25: the search box promised repositories, but only the
    # repository a message arrived with was searched, and a request's work
    # names its repository on the working copy it checks out.
    {:ok, %{episode: episode}} = Episodes.apply(Fixtures.admit_input())

    {:ok, session} =
      Custody.pin_episode(episode.id, "search-repository", String.duplicate("a", 64))

    Repo.update_all(from(s in Session, where: s.id == ^session.id),
      set: [repository_ref: "acme/checkout-api"]
    )

    assert %{total: 1, items: [item]} = Activity.list(%{"q" => "acme/checkout-api"})
    assert item.id == episode.id
    assert item.repository == "acme/checkout-api"
    assert Activity.list(%{"q" => "acme/billing-api"}).total == 0
  end

  # Search and the Repository filter missed what a row shows: the name Work gave the request, the
  # repository as owner/repo, the channel by its name. The filter also matched the repository the
  # work checked out while the row showed the one its message came with (2026-10-04 review).
  test "search and the repository filter find a request by what its row shows" do
    start_supervised!({Names, workspace: "T123", fetch: fn _ref -> {:ok, "ops-alerts"} end})
    Names.name("T123", "C777")
    assert :ok = GenServer.call(Names, :refresh)

    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "U2"},
        channel_ref: "C777",
        content: %{"text" => "Requests are failing"},
        event_kind: :message,
        event_ref: "Ev-what-a-row-shows",
        message_ref: "1788370104.000100",
        occurred_at: DateTime.utc_now(),
        revision: 1,
        thread_ref: nil,
        workspace_ref: "T123"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)

    {:ok, %{episode: episode}} =
      Episodes.apply(
        Fixtures.admit_input(%{
          destination: %{conversation_ref: "slack:T123:C777", thread_ref: nil, transport: "slack"}
        })
      )

    Repo.update_all(from(e in Entry, where: e.id == ^entry.id),
      set: [
        episode_id: episode.id,
        repository_ref: "repo:payments",
        work_policy: "row-shows",
        work_policy_digest: String.duplicate("b", 64),
        status: :decided,
        decision_action: :start_episode,
        decision_ref: "decision:what-a-row-shows",
        decision_fingerprint: String.duplicate("a", 64),
        decision_document: %{"action" => "start_episode", "episode_ref" => episode.key}
      ]
    )

    {:ok, session} = Custody.pin_episode(episode.id, "row-shows", String.duplicate("a", 64))

    Repo.update_all(from(s in Session, where: s.id == ^session.id),
      set: [repository_ref: "repo:ledger"]
    )

    {1, _} =
      Repo.update_all(
        from(digest in Ryker.Episodes.RoutingDigest, where: digest.episode_id == ^episode.id),
        set: [
          title: "Investigate the 502s",
          title_turn_id: Ecto.UUID.generate(),
          title_updated_at: DateTime.utc_now()
        ]
      )

    Repo.insert_all("removed_repository_names", [
      %{ref: "repo:payments", name: "acme/payments-api", inserted_at: DateTime.utc_now()}
    ])

    assert %{items: [row]} = Activity.list(%{})
    assert row.title == "Investigate the 502s"
    assert row.repository == "acme/payments-api"

    for shown <- ["the 502s", "acme/payments", "#ops-alerts", "ops-alerts"] do
      assert Activity.list(%{"q" => shown}).total == 1, "search for #{shown} found nothing"
    end

    assert Activity.list(%{"repository" => "repo:payments"}).total == 1
    assert Activity.list(%{"repository" => "repo:ledger"}).total == 0
  end

  # A reply Slack would not take stops its request for a person, but Activity read it as running,
  # and leaving it as it is on Failures changed nothing there (2026-10-04 review).
  test "a refused reply needs a person in Activity until they leave it" do
    entry =
      Answers.slack_message!(
        channel: "C778",
        text: "Is checkout healthy?",
        ts: "1788370105.000100",
        workspace: "T123"
      )

    %{turn: turn} = Answers.blocked_reply!(entry, "Checkout is healthy.", "slack_api_error")
    assert turn.status == :blocked
    assert Activity.list(%{}).views["attention"] == 1

    assert {:ok, _left} =
             FailureDismissals.leave(
               "delivery",
               turn.delivery_ref,
               "slack_api_error",
               "control-plane:local"
             )

    assert %{"attention" => 0, "done" => 1} = Activity.list(%{}).views
  end

  test "a usage filter chosen without a period covers all of a request's history" do
    # QA, 2026-09-25: choosing a model also added "Usage period Last 7 days";
    # without that chip the filter would still have quietly dropped older work.
    {:ok, %{episode: episode}} = Episodes.apply(Fixtures.admit_input())

    Repo.insert!(%Ryker.Accounting.Execution{
      kind: "work",
      source_id: Ecto.UUID.generate(),
      generation: "1",
      episode_id: episode.id,
      transport: "slack",
      conversation_ref: episode.destination_conversation_ref,
      execution_mode: "live",
      remote_ref: "usage-all-time",
      status: "completed",
      execution_target: "codex:gpt-5.6-terra/high@default",
      usage_recorded: true,
      usage_input_tokens: 10,
      recorded_at: DateTime.add(DateTime.utc_now(), -40, :day)
    })

    assert Activity.list(%{"usage_model" => "gpt-5.6-terra"}).total == 1
    assert Activity.list(%{"usage_model" => "gpt-5.6-terra", "usage_window" => "7d"}).total == 0
  end

  test "a scheduled run is named by its schedule, not as a message that went missing" do
    # QA, 2026-09-25: every scheduled run in Activity read "Message text no
    # longer available". A run starts from its schedule, not from a message,
    # so there was never text to lose.
    source = SavedEntities.source!("slack:T123:C456")
    schedule = SavedEntities.schedule!(source, "Weekday open incident status", 1)
    run = counted_episode!("scheduled-run")

    %{
      child_episode_id: run.id,
      event_ref: "schedule-event:" <> run.id,
      id: Ecto.UUID.generate(),
      ref: "schedule-occurrence:" <> run.id,
      schedule_id: schedule.id,
      scheduled_for: DateTime.utc_now(),
      status: :dispatched
    }
    |> ScheduleOccurrenceChangeset.insert()
    |> Repo.insert!()

    assert %{title: "Weekday open incident status"} =
             Enum.find(Activity.list(%{}).items, &(&1.id == run.id))

    assert Activity.list(%{"q" => "weekday open incident"}).total == 1
  end

  # Andrew, 2026-10-01, of Activity rows reading "Message text no longer available": a task is
  # started by its confirmation, not by a message, so its row "should be the task title", and the
  # row should say what kind of request it is ("eg this one is engineering task"). An answer given
  # on a question card has no text either; it reads as the answer.
  test "a task reads as its task, and a card answer as what was chosen" do
    asked = counted_episode!("task-asked")
    {:ok, _session} = Custody.pin_episode(asked.id, "ryker-read", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("worker:activity-task", 60, :work)
    task = counted_episode!("task-run")

    payload = %{
      "kind" => "engineering",
      "prompt" => "Add the file.",
      "repository" => "test",
      "title" => "Demo: add a greeting file"
    }

    Repo.insert!(%Ryker.Records.Record{
      id: Ecto.UUID.generate(),
      confirmation_ref: "confirmation:activity-task",
      confirmed_at: DateTime.utc_now(),
      confirmed_by_actor_ref: "local-operator",
      confirmed_episode_id: task.id,
      episode_id: asked.id,
      kind: "task_offer",
      operation_id: "task",
      payload: payload,
      payload_fingerprint: Ryker.CanonicalJSON.digest(payload),
      ref: "record:task_offer:activity",
      status: :confirmed,
      turn_id: claim.turn.id
    })

    row = Enum.find(Activity.list(%{}).items, &(&1.id == task.id))
    assert row.title == "Demo: add a greeting file"
    assert row.kind_label == "Engineering task"

    {:ok, input} =
      Ryker.Ingress.Input.new(%{
        actor: %{kind: :user, ref: "local-operator"},
        content: %{
          "choice" => "Sunglasses",
          "choice_index" => 2,
          "input_request_ref" => "record:input_request:activity",
          "interaction_kind" => "button"
        },
        destination: %{
          conversation_ref: "control-plane:lab:activity",
          thread_ref: "control-plane:lab:activity",
          transport: "control_plane"
        },
        event_kind: :event,
        event_ref: "control-plane-action:activity",
        native_input_id: "control-plane-response:activity",
        occurred_at: DateTime.utc_now(),
        occurred_at_source: :ingress,
        revision: 1,
        source: %{kind: "control_plane", ref: "local"},
        source_capabilities: %{},
        source_item_ref: "control-plane-action:activity"
      })

    {:ok, %{entry: answer}} = Inbox.record(input)

    assert Enum.find(Activity.list(%{}).items, &(&1.id == answer.id)).title ==
             ~s(Answered "Sunglasses")
  end

  # Manual testing, 2026-09-26: deleting a message added a second row,
  # "Message deleted · No response needed", beside the message's own row, and
  # counted the deletion as one more request.
  test "a deleted message stays one row, and its deletion is not a request of its own" do
    for {kind, revision, ref} <- [
          {:message, 1, "Ev-activity-delete-1"},
          {:delete, 2, "Ev-activity-delete-2"}
        ] do
      {:ok, input} =
        Input.new(%{
          actor: %{kind: :user, ref: "U123"},
          channel_ref: "C456",
          content: %{"text" => "thanks"},
          event_kind: kind,
          event_ref: ref,
          message_ref: "1787832188.000100",
          occurred_at: DateTime.add(DateTime.utc_now(), revision),
          revision: revision,
          thread_ref: nil,
          workspace_ref: "T123"
        })

      {:ok, _recorded} = Inbox.record(input)
    end

    assert %{total: 1, items: [row]} = Activity.list(%{})
    assert row.kind == "admission"
  end

  # Andrew, 2026-09-26: Slack delivers a message that mentions Ryker twice, as a
  # channel message and as a mention, and both copies of "Hi @Ryker" in #test
  # read "● Queued" on Activity while routing worked on them, the second after
  # Ryker had already answered "Hi! How can I help?" in the thread. Queued is a
  # message waiting for routing to pick it up; one routing is deciding says so,
  # and one routing answered says what it sent.
  test "a Slack message routing is answering never reads Queued" do
    [first, second] =
      for event_ref <- ["Ev-hi-channel-message", "Ev-hi-app-mention"] do
        {:ok, input} =
          Input.new(%{
            actor: %{kind: :user, ref: "U123"},
            channel_ref: "C456",
            content: %{"text" => "Hi <@U0C1LCVNF52>"},
            event_kind: :message,
            event_ref: event_ref,
            message_ref: "1788562304.000100",
            occurred_at: DateTime.utc_now(),
            revision: 1,
            thread_ref: nil,
            workspace_ref: "T123"
          })

        {:ok, %{entry: entry}} = Inbox.record(input)
        entry
      end

    now = DateTime.utc_now()
    assert {:ok, %{entry: %{id: claimed}}} = Inbox.claim_next("routing:test", now, 300)
    assert claimed == first.id
    assert state(first) == "Routing"
    assert state(second) == "Queued"

    decision = %{
      "action" => "quick_reply",
      "message" => "Hi! How can I help?",
      "reason" => "A greeting needs a short answer."
    }

    Repo.update_all(from(e in Entry, where: e.id == ^first.id),
      set: [
        status: :decided,
        decision_action: :quick_reply,
        decision_ref: "decision:#{first.id}",
        decision_fingerprint: String.duplicate("a", 64),
        decision_document: decision,
        lease_ref: nil,
        lease_owner: nil,
        lease_expires_at: nil
      ]
    )

    assert {:ok, %{entry: %{id: claimed}}} = Inbox.claim_next("routing:test", now, 300)
    assert claimed == second.id
    assert state(first) == "Answered right away"
    assert state(second) == "Routing"
  end

  defp state(entry) do
    row = Enum.find(Activity.list(%{}).items, &(&1.id == entry.id))
    row.state |> ActivityPage.state() |> elem(1)
  end

  test "every workload count opens a view that lists exactly that many requests" do
    # QA, 2026-09-25: Activity led with "3 active · 2 waiting · 1 blocked" while
    # In progress listed nothing, and "waiting" and "blocked" both opened the
    # same Needs you view. "Active" counted waiting work, blocked work and
    # evaluations, none of which In progress lists, so every number on the row
    # disagreed with the list it opened.
    blocked = counted_episode!("blocked")

    {:ok, _session} =
      Custody.pin_episode(blocked.id, "counts-test", String.duplicate("a", 64))

    {:ok, _claim} = Custody.claim_next("counts-test", 60, :work)

    {1, _} =
      Repo.update_all(from(t in Turn, where: t.episode_id == ^blocked.id),
        set: [
          status: :blocked,
          lease_ref: nil,
          lease_owner: nil,
          lease_expires_at: nil,
          next_attempt_at: nil
        ]
      )

    for {name, kind} <- [{"question", :input}, {"watch", :event}] do
      episode = counted_episode!(name)

      {:ok, _} =
        Episodes.apply(
          Fixtures.start_wait(%{
            episode_key: episode.key,
            expected_turn_ref: episode.owner_ref,
            kind: kind,
            wait_ref: "#{name}:#{episode.id}"
          })
        )
    end

    _working = counted_episode!("working")
    evaluation = counted_episode!("evaluation")

    Repo.update_all(from(e in Ryker.Episodes.Episode, where: e.id == ^evaluation.id),
      set: [execution_mode: :shadow]
    )

    counts =
      render_component(&ActivityPage.render/1,
        activity: Activity.list(%{}),
        fleet: OverviewProjection.fleet(),
        params: %{},
        path: "/activity",
        now: DateTime.utc_now(),
        stream: [],
        new_items: 0,
        schedules: []
      )
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(".kit-counts a.kit-count")
      |> Enum.map(fn count ->
        {count |> LazyHTML.query("b") |> LazyHTML.text() |> String.to_integer(),
         count |> LazyHTML.text() |> String.split() |> tl() |> Enum.join(" "),
         count |> LazyHTML.attribute("href") |> hd()}
      end)

    for {value, label, href} <- counts do
      listed = href |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

      assert Activity.list(listed).total == value,
             "\"#{value} #{label}\" opens #{href}, which lists #{Activity.list(listed).total}"
    end

    assert counts |> Enum.map(&elem(&1, 2)) |> Enum.uniq() |> length() == length(counts),
           "two counts open the same view: #{inspect(counts)}"

    assert Enum.map(counts, &{elem(&1, 0), elem(&1, 1)}) == [{2, "in progress"}, {2, "need you"}]
  end

  # Leaving a stopped message as it is on Failures (Andrew, 2026-10-03: "how do I hide the alert
  # if I want to leave it and not be annoyed by having a failure pending forever?") must also stop
  # Activity counting it as needing someone, or the count still nags. Failing some other way
  # counts it again; a retry that fails the same way does not.
  test "a stopped message left as it is on Failures needs nobody while it fails the same way" do
    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "U123"},
        channel_ref: "C456",
        content: %{"text" => "Route this one please"},
        event_kind: :message,
        event_ref: "Ev-left-as-it-is",
        message_ref: "1787832199.000100",
        occurred_at: DateTime.utc_now(),
        revision: 1,
        thread_ref: nil,
        workspace_ref: "T123"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)
    {:ok, %{lease_ref: lease}} = Inbox.claim_next("slot:left", DateTime.utc_now(), 60)
    assert {:ok, _blocked} = Inbox.block(Inbox.ref(entry), lease, "blocked", "stopped")
    assert %{views: %{"attention" => 1}, items: [%{bucket: "attention"}]} = Activity.list(%{})

    assert {:ok, _left} = Actions.callbacks().leave_failure.("admission", Inbox.ref(entry), nil)
    assert %{views: %{"attention" => 0}, items: [%{bucket: "done"}]} = Activity.list(%{})

    blocked = Repo.get!(Entry, entry.id)

    Repo.update_all(from(e in Entry, where: e.id == ^entry.id),
      set: [updated_at: DateTime.add(blocked.updated_at, 1, :second)]
    )

    assert %{views: %{"attention" => 0}} = Activity.list(%{})

    Repo.update_all(from(e in Entry, where: e.id == ^entry.id),
      set: [last_error_code: "admission_unavailable"]
    )

    assert %{views: %{"attention" => 1}} = Activity.list(%{})
  end

  defp counted_episode!(name) do
    id = Ecto.UUID.generate()

    {:ok, %{episode: episode}} =
      Episodes.apply(
        Fixtures.admit_input(%{
          episode_id: id,
          episode_key: "counts:#{name}:#{id}",
          native_input_id: "counts:#{name}:#{id}",
          turn_ref: "counts-turn:#{name}:#{id}"
        })
      )

    episode
  end
end
