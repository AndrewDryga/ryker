defmodule Ryker.Episodes.ReactionsTest do
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.Episodes
  alias Ryker.Episodes.{Event, Reactions, Transition}
  alias Ryker.Feedback
  alias Ryker.Fixtures.Answers

  @now ~U[2026-09-03 09:00:00.000000Z]

  test "passive feedback rejects malformed authority before resolving a target" do
    valid = %{
      action: :add,
      actor_ref: "U123",
      emoji_name: "eyes",
      event_ref: "Ev-reaction",
      occurred_at: @now,
      source: %{kind: "slack", ref: "T8BABF9A8D74D"},
      target: %{
        conversation_ref: "slack:T8BABF9A8D74D:C456",
        message_ref: "1787832000.000100",
        transport: "slack"
      }
    }

    cases = [
      {:fields, Map.put(valid, :authority, "approve")},
      {:action, %{valid | action: :approve}},
      {:actor_ref, %{valid | actor_ref: ""}},
      {:emoji_name, %{valid | emoji_name: "eyes:ship"}},
      {:event_ref, %{valid | event_ref: ""}},
      {:occurred_at, %{valid | occurred_at: DateTime.to_iso8601(@now)}},
      {:source, %{valid | source: %{kind: "slack", ref: "T8BABF9A8D74D", role: "admin"}}},
      {:target, %{valid | target: Map.put(valid.target, :repository, "other/repo")}},
      {:transport, put_in(valid, [:target, :transport], "control_plane")}
    ]

    Enum.each(cases, fn {field, attributes} ->
      assert Reactions.record(attributes) ==
               {:error, {:invalid_conversation_reaction, field}}
    end)

    assert Reactions.record(%{}) == {:error, {:invalid_conversation_reaction, :fields}}
    assert Reactions.record(:reaction) == {:error, {:invalid_conversation_reaction, :fields}}
    assert Reactions.record(valid) == {:error, :conversation_reaction_target_not_found}
  end

  test "empty and invalid projections remain bounded empty documents" do
    assert Reactions.current_for_episodes([]) == %{}
    assert Reactions.current_for_episodes(:all) == %{}

    assert Reactions.model_context(nil, 0) == %{
             "current" => [],
             "events" => []
           }
  end

  # Andrew, 2026-09-27: every answer records the feedback it gets. A reaction
  # on a Work reply was already the episode's event, read by the next turn;
  # it is now also feedback on the answer, in the same transaction, so the
  # two can never disagree about whether a reaction happened.
  test "a reaction on a Work reply is the request's event and feedback on the answer, once" do
    workspace = "TREACTFEEDBACK"
    channel = "CREACTWORK#{System.unique_integer([:positive])}"

    question =
      Answers.slack_message!(
        workspace: workspace,
        channel: channel,
        text: "Is checkout up?",
        ts: "1790010000.000100"
      )

    reply =
      Answers.work_reply!(
        question,
        "Checkout is up.",
        "1790010060.000100",
        Answers.slack_time("1790010060.000100")
      )

    reaction = %{
      action: :add,
      actor_ref: "UBOB",
      emoji_name: "-1",
      event_ref: "Ev-reaction-work",
      occurred_at: ~U[2026-09-27 12:00:00.000000Z],
      source: %{kind: "slack", ref: workspace},
      target: %{
        conversation_ref: question.destination_conversation_ref,
        message_ref: "1790010060.000100",
        transport: "slack"
      }
    }

    assert {:ok, %Transition{status: :applied, event: %{kind: :reaction_recorded}}} =
             Reactions.record(reaction)

    assert [signal] = Feedback.for_request({:episode, reply.episode.id})

    assert {signal.kind, signal.value, signal.category, signal.actor_ref, signal.source,
            signal.source_ref} ==
             {:reaction_added, "-1", :frustrated, "UBOB", "slack", "Ev-reaction-work"}

    # Slack redelivers an event it thinks was missed: still one reaction.
    assert {:ok, %Transition{status: :duplicate}} = Reactions.record(reaction)
    assert [^signal] = Feedback.for_request({:episode, reply.episode.id})

    assert {:ok, %Transition{status: :applied}} =
             Reactions.record(%{
               reaction
               | action: :remove,
                 event_ref: "Ev-reaction-work-removed",
                 occurred_at: ~U[2026-09-27 12:00:05.000000Z]
             })

    assert Enum.map(Feedback.for_request({:episode, reply.episode.id}), &{&1.kind, &1.category}) ==
             [{:reaction_added, :frustrated}, {:reaction_removed, :neutral}]
  end

  # A reaction on a quick reply or an update was dropped as "target not found":
  # routing's own answers had no way to hear that someone found them wrong.
  test "a reaction on a quick reply or a posted update is feedback on its request and wakes nothing" do
    workspace = "TREACTFEEDBACK"
    channel = "CREACTOTHER#{System.unique_integer([:positive])}"
    conversation_ref = "slack:#{workspace}:#{channel}"

    greeting =
      Answers.slack_message!(
        workspace: workspace,
        channel: channel,
        text: "Count to three",
        ts: "1790011000.000100"
      )

    Answers.quick_reply!(
      greeting,
      "1, 2, 3.",
      "1790011002.000100",
      Answers.slack_time("1790011002.000100")
    )

    question =
      Answers.slack_message!(
        workspace: workspace,
        channel: channel,
        text: "Why is billing slow?",
        ts: "1790011100.000100"
      )

    reply =
      Answers.work_reply!(
        question,
        "The report query is slow.",
        "1790011160.000100",
        Answers.slack_time("1790011160.000100")
      )

    Answers.post!(
      reply,
      "Still checking the replicas.",
      "1790011130.000100",
      Answers.slack_time("1790011130.000100")
    )

    events_before =
      Repo.aggregate(from(event in Event, where: event.episode_id == ^reply.episode.id), :count)

    react = fn message_ref, event_ref, emoji ->
      Reactions.record(%{
        action: :add,
        actor_ref: "UALICE",
        emoji_name: emoji,
        event_ref: event_ref,
        occurred_at: ~U[2026-09-27 12:00:00.000000Z],
        source: %{kind: "slack", ref: workspace},
        target: %{
          conversation_ref: conversation_ref,
          message_ref: message_ref,
          transport: "slack"
        }
      })
    end

    assert {:ok, %{status: :applied}} = react.("1790011002.000100", "Ev-quick", "+1")
    assert {:ok, %{status: :duplicate}} = react.("1790011002.000100", "Ev-quick", "+1")

    assert [%{kind: :reaction_added, value: "+1", category: :satisfied}] =
             Feedback.for_request({:input, greeting.id})

    assert {:ok, %{status: :applied}} = react.("1790011130.000100", "Ev-post", "eyes")

    assert [%{kind: :reaction_added, value: "eyes", category: :neutral}] =
             Feedback.for_request({:episode, reply.episode.id})

    # Neither is the episode's event: the next Work turn is not told about it.
    assert Repo.aggregate(
             from(event in Event, where: event.episode_id == ^reply.episode.id),
             :count
           ) ==
             events_before

    assert {:ok, episode} = Episodes.fetch_by_key(reply.episode.key)
    assert episode.state == reply.episode.state

    # A message Ryker never sent is still nobody's answer.
    assert react.("1790011999.000100", "Ev-nobody", "+1") ==
             {:error, :conversation_reaction_target_not_found}
  end
end
