defmodule Ryker.ControlPlane.IsolatedFailureTest do
  @moduledoc """
  One unreadable card must not take the page down with it.

  The Timeline reads evidence written by many owners over a long time, some of
  it by versions that no longer exist. A payload that does not parse is an
  ordinary occurrence, and the operator reading the page is usually reading it
  because something already went wrong: losing every other card to one bad row
  removes the evidence they came for.
  """
  use Ryker.DataCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Ryker.CanonicalJSON
  alias Ryker.ControlPlane.{EpisodePage, ModelRequests, Projection}
  alias Ryker.Episodes
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Slack.Input
  alias Ryker.Work.{ActivityEvent, Custody, Session}

  @now ~U[2026-09-04 22:51:44.000000Z]

  test "an unreadable tool payload leaves every other card on the page" do
    %{episode: episode, session: session} = admitted!("tool")

    for {kind, payload} <- [
          {"tool.completed", %{"tool_call_id" => nil, "status" => nil, "input" => "not a map"}},
          {"model.plan", %{"entries" => "not a list", "step_count" => "many"}},
          {"permission.decided", %{"outcome" => %{"nested" => "not a string"}}}
        ] do
      activity!(episode, session, kind, payload)
    end

    html = rendered(episode)

    assert html =~ "Intake"
    assert html =~ "Standing rules"
    assert html =~ "Input queue"
    assert html =~ "Investigate tool"
  end

  test "an unreadable engagement receipt is one card's absence, not the page's" do
    %{episode: episode, entry: entry} = admitted!("receipt")

    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [
        engagement_receipt: %{"result" => %{"unexpected" => "shape"}, "checks" => "not a list"}
      ]
    )

    html = rendered(episode)

    assert html =~ "Participation"
    assert html =~ "Standing rules"
    assert html =~ "Input queue"
  end

  test "a malformed delivery document does not erase the rest of the timeline" do
    %{episode: episode} = admitted!("delivery")

    Repo.update_all(from(turn in Ryker.Work.Turn, where: turn.episode_id == ^episode.id),
      set: [delivery_document: %{"delivery" => %{"unexpected" => true}, "message" => 17}]
    )

    html = rendered(episode)
    assert html =~ "Intake"
    assert html =~ "Investigate delivery"
  end

  defp rendered(episode) do
    {:ok, detail} = Projection.episode(episode.key)
    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})

    render_component(&EpisodePage.render/1,
      snapshot: detail,
      timeline: timeline,
      requests: nil,
      params: %{}
    )
  end

  defp activity!(episode, session, kind, payload) do
    Repo.insert!(%ActivityEvent{
      coop_turn_id: "coop-turn-#{System.unique_integer([:positive])}",
      episode_id: episode.id,
      kind: kind,
      occurred_at: DateTime.add(@now, 30, :second),
      payload: payload,
      payload_fingerprint: CanonicalJSON.digest(payload),
      remote_event_id: "isolated:#{System.unique_integer([:positive])}",
      remote_session_id: "remote:#{session.id}",
      sequence: System.unique_integer([:positive]),
      session_id: session.id,
      version: 1
    })
  end

  defp admitted!(suffix) do
    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "U123"},
        channel_ref: "C456",
        content: %{"text" => "Investigate #{suffix}"},
        event_kind: :message,
        event_ref: "Ev-isolated-#{Ecto.UUID.generate()}",
        message_ref: "#{1_788_562_304 + System.unique_integer([:positive])}.000100",
        occurred_at: @now,
        revision: 1,
        thread_ref: nil,
        workspace_ref: "TC9F5B40D364C"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)

    {:ok, %{episode: episode}} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          episode_id: entry.id,
          episode_key: "isolated:#{suffix}:#{entry.id}",
          native_input_id: entry.native_input_id,
          occurred_at: @now,
          payload: Ryker.Ingress.Input.document(input),
          turn_ref: "ingress-turn:#{entry.id}"
        })
      )

    {:ok, _pinned} = Custody.pin_episode(episode.id, "isolated", String.duplicate("a", 64))
    {:ok, _claim} = Custody.claim_next("isolated:#{suffix}", 120, :work)
    session = Repo.one!(from(s in Session, where: s.episode_id == ^episode.id))

    decision = %{"action" => "reply", "reason" => "A direct reply."}

    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [
        decision_action: :reply,
        decision_document: decision,
        decision_fingerprint: CanonicalJSON.digest(decision),
        decision_ref: "decision:#{entry.id}",
        episode_id: episode.id,
        status: :decided
      ]
    )

    %{episode: episode, entry: Repo.get!(Entry, entry.id), session: session}
  end
end
