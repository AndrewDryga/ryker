defmodule Ryker.ControlPlane.ActivityTest do
  use Ryker.DataCase, async: false
  import Ecto.Query
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{Activity, ActivityPage, Projection, SlackNames, UsagePage}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: Fixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.Slack.Input
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
      {SlackNames,
       workspace: "T123",
       fetch: fn ref ->
         send(parent, {:lookup, ref})
         {:ok, if(String.starts_with?(ref, "U"), do: "emisar", else: "test")}
       end}
    )

    SlackNames.name("T123", "U1")
    SlackNames.name("T123", "C456")
    assert :ok = GenServer.call(SlackNames, :refresh)
    assert :ok = GenServer.call(SlackNames, :refresh)

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
        actor: %{kind: :bot, ref: "B08N64XSHNU"},
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

    assert Projection.usage(%{}).totals.attempts == 1

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
    assert item.href == "/timeline/ingress-input%3A#{entry.id}"
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
    assert item.href == "/timeline/#{URI.encode_www_form(episode.key)}"

    assert %{title: "Inspect the slow admission request"} =
             Activity.request_titles([episode.key])[episode.key]

    {:ok, _session} = Custody.pin_episode(episode.id, "label-test", String.duplicate("a", 64))

    # Direct conversation work has a worker session but no repository checkout.
    assert Projection.workspaces(%{}) == []

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
        overview: %{},
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
    assert item.href == "/timeline/paging"

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
      snapshot = Projection.usage(%{"mode" => mode})
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

    {:ok, detail} = Projection.episode(episode.key)
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
    source = Ryker.Fixtures.SavedEntities.source!("slack:T123:C456")
    schedule = Ryker.Fixtures.SavedEntities.schedule!(source, "Weekday open incident status", 1)
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
    |> Ryker.State.ScheduleOccurrenceChangeset.insert()
    |> Repo.insert!()

    assert %{title: "Weekday open incident status"} =
             Enum.find(Activity.list(%{}).items, &(&1.id == run.id))

    assert Activity.list(%{"q" => "weekday open incident"}).total == 1
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
        overview: Projection.overview(),
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
