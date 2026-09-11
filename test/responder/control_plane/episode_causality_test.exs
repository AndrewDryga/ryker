defmodule Responder.ControlPlane.EpisodeCausalityTest do
  @moduledoc """
  Grouping by durable ownership rather than by the nearest message.

  Reading a timeline is how an operator answers "why did it do that", and the
  answer is worthless if the evidence is filed under the wrong cause. Work
  routinely overlaps a new message: a tool that Turn 1 called can return after
  Message 2 arrives. Filing that receipt under Message 2 tells the operator the
  system reacted to a message that did not exist when the call was made. These
  tests hold the ownership rules that make the page answerable.
  """
  use Responder.DataCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Responder.CanonicalJSON
  alias Responder.ControlPlane.{EpisodeCausality, EpisodePage, ModelRequests, Projection}
  alias Responder.Episodes
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Ingress.Inbox
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Slack.Input
  alias Responder.Work.{ActivityEvent, Custody, SubmissionBuilder, Turn}

  @now ~U[2026-09-04 22:51:44.000000Z]

  test "a tool result that lands after a newer message stays with the turn that called it" do
    %{episode: episode, turn: turn, session: session} = started_work()

    # Message 2 arrives while Turn 1 is still running.
    admit!(episode, "Ev2", DateTime.add(@now, 60, :second))

    late =
      activity!(episode.id, session.id, turn.coop_turn_id, 9, "tool.completed", %{
        "status" => "ok",
        "title" => "Read file",
        "tool_call_id" => "call-late"
      })

    chapters = chapters(episode)

    late_chapter =
      Enum.find(chapters, fn chapter ->
        Enum.any?(chapter.steps, &(&1.id == "event-activity-#{late.id}"))
      end)

    assert late_chapter, "the late receipt must still be rendered"

    # The whole point: the receipt keeps Turn 1's position, not Message 2's.
    assert late_chapter.conversation_turn == 1
    assert {:turn, turn.id} in late_chapter.owners
    refute {:input, second_input_id(episode)} in late_chapter.owners
  end

  test "a turn built from two inputs names both of them" do
    %{episode: episode, turn: turn} = started_work()

    admit!(episode, "Ev2", DateTime.add(@now, 30, :second))

    refs = kernel_input_refs(episode)
    assert length(refs) == 2
    record_selection!(turn, refs)

    index = index_for(episode)
    described = EpisodeCausality.describe(index, {:turn, turn.id})
    assert described.inputs == [1, 2]

    html = rendered(episode)
    assert html =~ "Inputs: Message 1 + Message 2"
  end

  test "an unrecorded input selection is not an empty selection" do
    # A turn frozen before the selection was captured has no recorded inputs.
    # Rendering that as "no inputs" would claim the model was given nothing,
    # and rendering the nearest message would blame the wrong one.
    %{episode: episode, turn: turn} = started_work()
    record_selection!(turn, nil)

    index = index_for(episode)
    assert EpisodeCausality.describe(index, {:turn, turn.id}).inputs == :not_recorded
  end

  test "a repeated or reordered event neither merges two turns nor multiplies one" do
    %{episode: episode, turn: turn, session: session} = started_work()

    for sequence <- [3, 5, 4] do
      activity!(episode.id, session.id, turn.coop_turn_id, sequence, "tool.started", %{
        "title" => "Read file",
        "tool_call_id" => "call-#{sequence}"
      })
    end

    index = index_for(episode)
    owners = Map.values(index.activity_owner) |> Enum.uniq()
    assert owners == [{:turn, turn.id}]

    chapters = chapters(episode)

    ids =
      chapters
      |> Enum.flat_map(& &1.steps)
      |> Enum.map(& &1.id)

    assert ids == Enum.uniq(ids), "a durable step id must appear once"
    assert Enum.any?(chapters, &match?(%{turn: %{kind: :turn}}, &1))
  end

  test "an input that never produced a turn keeps its own identity" do
    %{episode: episode} = started_work()
    index = index_for(episode)
    [input] = inputs(episode)

    described = EpisodeCausality.describe(index, {:input, input.id})
    assert described.kind == :input
    assert described.ordinal == 1
    assert EpisodeCausality.position(index, {:input, input.id}) == 1
  end

  defp started_work do
    episode = admit!(nil, "Ev1", @now)

    {:ok, session} = Custody.pin_episode(episode.id, "causality", String.duplicate("a", 64))
    {:ok, claim} = Custody.claim_next("causality", 60, :work)
    {:ok, submission} = SubmissionBuilder.build(claim)

    {:ok, turn} =
      Custody.freeze_submission(
        claim.episode.id,
        claim.turn.turn_ref,
        claim.lease_ref,
        submission,
        selected_input_refs: Enum.uniq(claim.episode.active_input_refs)
      )

    turn =
      turn
      |> Ecto.Changeset.change(coop_turn_id: "remote-turn:#{session.id}")
      |> Repo.update!()

    %{episode: episode, session: session, turn: turn}
  end

  # Records one real inbox input and admits it, exactly as ingress does: the
  # inbox row and the kernel event are separate records joined by turn_ref.
  defp admit!(episode, event_ref, occurred_at) do
    {:ok, input} =
      Input.new(%{
        actor: %{kind: :user, ref: "U123"},
        channel_ref: "C456",
        content: %{"text" => "Investigate #{event_ref}"},
        event_kind: :message,
        event_ref: event_ref,
        message_ref: "1788562304.0001#{String.slice(event_ref, -2, 2)}",
        occurred_at: occurred_at,
        revision: 1,
        thread_ref: nil,
        workspace_ref: "TC9F5B40D364C"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)

    attributes = %{
      actor_ref: "slack:user:U123",
      destination: %{
        conversation_ref: "slack:TC9F5B40D364C:C456",
        thread_ref: "1788562304.000100",
        transport: "slack"
      },
      native_input_id: entry.native_input_id,
      occurred_at: occurred_at,
      payload: Responder.Ingress.Input.document(input),
      turn_ref: "ingress-turn:#{entry.id}"
    }

    attributes =
      if episode,
        do: Map.merge(attributes, %{episode_id: episode.id, episode_key: episode.key}),
        else:
          Map.merge(attributes, %{episode_id: entry.id, episode_key: "ingress-input:#{entry.id}"})

    {:ok, %{episode: episode}} =
      Episodes.apply(EpisodeFixtures.admit_input(attributes))

    Repo.update_all(from(saved in Entry, where: saved.id == ^entry.id),
      set: [
        decision_action: :start_episode,
        decision_ref: "decision:#{entry.id}",
        decision_fingerprint: String.duplicate("a", 64),
        decision_document: %{"action" => "start_episode", "episode_ref" => episode.key},
        episode_id: episode.id,
        status: :decided
      ]
    )

    episode
  end

  defp kernel_input_refs(episode) do
    Repo.all(
      from(event in Responder.Episodes.Event,
        where: event.episode_id == ^episode.id and event.kind == :input_admitted,
        order_by: [asc: event.sequence],
        select: event.dedupe_key
      )
    )
  end

  defp record_selection!(turn, refs) do
    Repo.update_all(from(t in Turn, where: t.id == ^turn.id), set: [selected_input_refs: refs])
  end

  defp activity!(episode_id, session_id, coop_turn_id, sequence, kind, payload) do
    Repo.insert!(%ActivityEvent{
      coop_turn_id: coop_turn_id,
      episode_id: episode_id,
      kind: kind,
      occurred_at: DateTime.add(@now, 60 + sequence, :second),
      payload: payload,
      payload_fingerprint: CanonicalJSON.digest(payload),
      remote_event_id: "causality-event:#{sequence}",
      remote_session_id: "remote-session:#{session_id}",
      sequence: sequence,
      session_id: session_id,
      version: 1
    })
  end

  defp inputs(episode) do
    Repo.all(
      from(entry in Responder.Ingress.Inbox.Entry,
        where: entry.episode_id == ^episode.id,
        order_by: [asc: entry.occurred_at, asc: entry.id]
      )
    )
  end

  defp second_input_id(episode), do: episode |> inputs() |> Enum.at(1) |> Map.get(:id)

  defp index_for(episode) do
    {:ok, detail} = Projection.episode(episode.key)
    detail.trace.causality
  end

  defp chapters(episode) do
    {:ok, detail} = Projection.episode(episode.key)
    {:ok, timeline} = ModelRequests.timeline(episode.key, %{})
    EpisodePage.chapters(detail, timeline)
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
end
