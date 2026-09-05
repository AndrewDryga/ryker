defmodule Responder.ControlPlane.ActivityTest do
  use Responder.DataCase, async: false
  import Ecto.Query
  alias Responder.ControlPlane.{Activity, HTML, Projection}
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: Fixtures
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Repo
  alias Responder.Slack.Input
  alias Responder.Work.Custody
  alias Responder.Work.Session
  alias Responder.Work.Turn

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
    assert item.href == "/admission/#{entry.id}"
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
    assert item.href == "/episodes/#{URI.encode_www_form(episode.key)}"

    assert %{title: "Inspect the slow admission request"} =
             Activity.request_titles([episode.key])[episode.key]

    assert Enum.all?(Projection.audit(%{}), &(&1.request_title == item.title))
    {:ok, _session} = Custody.pin_episode(episode.id, "label-test", String.duplicate("a", 64))
    assert [%{request_title: "Inspect the slow admission request"}] = Projection.workspaces(%{})
  end

  test "activity uses human fallback labels and never passes secrets or shadow traffic as live" do
    {:ok, %{episode: episode}} = Episodes.apply(Fixtures.admit_input())
    assert %{items: [item]} = Activity.list(%{})
    assert item.title == "Slack conversation · source content unavailable"
    refute item.title =~ episode.key

    Repo.update_all(from(e in Responder.Episodes.Episode, where: e.id == ^episode.id),
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

      html = snapshot |> HTML.usage() |> IO.iodata_to_binary()

      links =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("a[href^='/episodes?']")
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
