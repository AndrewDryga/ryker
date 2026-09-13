defmodule Ryker.ControlPlane.ActivityTest do
  use Ryker.DataCase, async: false
  import Ecto.Query
  import Phoenix.LiveViewTest
  alias Ryker.ControlPlane.{Activity, ActivityPage, HTML, Projection}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: Fixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.Slack.Input
  alias Ryker.Work.Custody
  alias Ryker.Work.Session
  alias Ryker.Work.Turn

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
    assert [%{request_title: "Inspect the slow admission request"}] = Projection.workspaces(%{})

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
        overview: %{counts: %{}},
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
      assert %{items: [], total: 0} = Activity.list(%{"state" => state})
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
    assert item.title == "Slack conversation · source content unavailable"
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
        snapshot |> Map.put(:models, snapshot.targets) |> HTML.usage() |> IO.iodata_to_binary()

      links =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("a[href^='/activity?']")
        |> LazyHTML.attribute("href")

      assert length(links) == 3
      assert Enum.all?(links, &(URI.decode_query(URI.parse(&1).query)["mode"] == mode))
    end
  end

  test "usage drill-down filters preserve episode identity, historical target and repository" do
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
    assert Activity.list(%{"target" => "sol/medium"}).total == 1
    assert Activity.list(%{"target" => "terra/medium"}).total == 0
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
end
