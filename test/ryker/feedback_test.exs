defmodule Ryker.FeedbackTest do
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.Episodes
  alias Ryker.Feedback
  alias Ryker.Feedback.Signal
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Slack.Input, as: SlackInput

  @now ~U[2026-09-27 12:00:00.000000Z]
  @workspace "TFEEDBACKSTORE"

  # Slack redelivers an event it thinks was missed, and a routing decision can
  # be committed again after a lost response. A reaction redelivered three
  # times is one reaction, not three votes about the answer.
  test "one event gives one signal of a kind, however often it arrives" do
    episode = episode!()

    attributes = %{
      kind: :reaction_added,
      value: "+1",
      actor_ref: "UALICE",
      source: "slack",
      source_ref: "slack-event:Ev-once",
      occurred_at: @now,
      request: {:episode, episode.id}
    }

    assert {:ok, %{status: :recorded, signal: first}} = Feedback.record(attributes)

    assert {:ok, %{status: :duplicate, signal: again}} =
             Feedback.record(%{attributes | occurred_at: DateTime.add(@now, 5, :second)})

    assert again.id == first.id
    assert again.occurred_at == @now

    assert Repo.aggregate(from(signal in Signal, where: signal.episode_id == ^episode.id), :count) ==
             1

    # The same event may still say something of another kind: the message that
    # asked again is also the one routing read a sentiment from.
    assert {:ok, %{status: :recorded}} =
             Feedback.record(%{attributes | kind: :reaction_removed})
  end

  test "each signal lands in the category the Feedback page groups it by, frustrated first" do
    assert Signal.categories() ==
             [:frustrated, :asked_again, :edited, :neutral, :satisfied, :reviewed]

    for {kind, value, category} <- [
          {:sentiment, "angry", :frustrated},
          {:sentiment, "frustrated", :frustrated},
          {:sentiment, "neutral", :neutral},
          {:sentiment, "satisfied", :satisfied},
          {:reaction_added, "-1", :frustrated},
          {:reaction_added, "confused", :frustrated},
          {:reaction_added, "+1", :satisfied},
          {:reaction_added, "tada", :satisfied},
          # Most emoji say nothing about how an answer landed.
          {:reaction_added, "eyes", :neutral},
          {:reaction_added, "fire", :neutral},
          {:reaction_removed, "+1", :neutral},
          {:reaction_removed, "-1", :neutral},
          {:asked_again, nil, :asked_again},
          {:message_edited, nil, :edited},
          {:message_deleted, nil, :edited},
          {:reviewed, "complete", :reviewed}
        ] do
      assert Feedback.category(kind, value) == category,
             "#{kind} #{inspect(value)} should be #{category}"
    end
  end

  test "a signal names one request, and a request that is gone records nothing" do
    episode = episode!()
    input = input!("Is checkout up?", "1790000000.000100")

    base = %{
      kind: :asked_again,
      actor_ref: "UALICE",
      source: "slack",
      occurred_at: @now
    }

    assert {:ok, %{signal: %{episode_id: nil, input_id: input_id}}} =
             Feedback.record(Map.merge(base, %{source_ref: "a", request: {:input, input.id}}))

    assert input_id == input.id

    assert {:ok, %{signal: %{episode_id: episode_id, input_id: nil}}} =
             Feedback.record(Map.merge(base, %{source_ref: "b", request: {:episode, episode.id}}))

    assert episode_id == episode.id

    assert Feedback.record(
             Map.merge(base, %{source_ref: "c", request: {:episode, Ecto.UUID.generate()}})
           ) == {:error, :feedback_request_not_found}

    for request <- [nil, {:episode, "not-a-uuid"}, {:thread, episode.id}] do
      assert Feedback.record(Map.merge(base, %{source_ref: "d", request: request})) ==
               {:error, {:invalid_feedback, :request}}
    end

    assert Feedback.record(Map.put(base, :source_ref, "e")) ==
             {:error, {:invalid_feedback, :request}}

    refute Repo.exists?(from(signal in Signal, where: signal.source_ref in ["c", "d"]))
  end

  test "a signal that does not fit its kind is refused before it reaches the table" do
    episode = episode!()

    base = %{
      kind: :sentiment,
      value: "frustrated",
      note: "Says the deploy time was wrong.",
      actor_ref: "UALICE",
      source: "slack",
      source_ref: "ingress-input:#{Ecto.UUID.generate()}",
      occurred_at: @now,
      request: {:episode, episode.id}
    }

    for {attributes, field} <- [
          {%{base | value: "happy"}, :value},
          {%{base | value: nil}, :value},
          {%{base | kind: :reviewed}, :value},
          {%{base | kind: :asked_again}, :value},
          {%{base | kind: :reaction_added, value: "Thumbs Up!"}, :value},
          {%{base | kind: :applauded}, :kind},
          {%{base | note: String.duplicate("a", 2_049)}, :note},
          {%{base | source: "Slack!"}, :source},
          {%{base | actor_ref: ""}, :actor_ref},
          {%{base | occurred_at: nil}, :occurred_at}
        ] do
      assert {:error, {:invalid_feedback, fields}} = Feedback.record(attributes)
      assert field in fields, "expected #{inspect(attributes)} to be refused for #{field}"
    end

    refute Repo.exists?(from(signal in Signal, where: signal.episode_id == ^episode.id))
    assert {:ok, %{status: :recorded}} = Feedback.record(base)
  end

  # The Feedback page and the request's Timeline redraw from what they hear;
  # a signal announced before its commit could be read before it exists, and
  # one announced from a rolled-back transaction would never exist at all.
  test "a signal is announced once it commits, on the request's topics too, and never on rollback" do
    episode = episode!()
    input = input!("Is checkout up?", "1790000001.000100")
    :ok = Feedback.subscribe_feedback()
    :ok = Episodes.subscribe_episode(episode.id)
    :ok = Inbox.subscribe_input(input.id)

    attributes = %{
      kind: :reaction_added,
      value: "-1",
      actor_ref: "UALICE",
      source: "slack",
      source_ref: "slack-event:Ev-announced",
      occurred_at: @now,
      request: {:episode, episode.id}
    }

    # The topic is shared by every test that records feedback, so each
    # announcement is looked for by the signal it names.
    assert {:error, {:rolled_back, rolled_back}} =
             Repo.transaction(fn ->
               {:ok, %{signal: %{id: id}}} = Feedback.record_in_transaction(attributes)
               Repo.rollback({:rolled_back, id})
             end)

    refute_received {:feedback_recorded, ^rolled_back}
    refute_received {:episode_updated, _id}

    assert {:ok, %{signal: %{id: id}}} = Feedback.record(attributes)
    assert_received {:feedback_recorded, ^id}
    episode_id = episode.id
    assert_received {:episode_updated, ^episode_id}

    # A duplicate changes nothing and says nothing.
    assert {:ok, %{status: :duplicate}} = Feedback.record(attributes)
    refute_received {:feedback_recorded, ^id}

    assert {:ok, %{signal: %{id: input_signal}}} =
             Feedback.record(%{
               attributes
               | source_ref: "slack-event:Ev-quick-reply",
                 request: {:input, input.id}
             })

    assert_received {:feedback_recorded, ^input_signal}
    input_id = input.id
    assert_received {:input_updated, ^input_id}
  end

  test "a request's feedback reads oldest first, bounded to the newest" do
    episode = episode!()

    for second <- 1..5 do
      assert {:ok, _recorded} =
               Feedback.record(%{
                 kind: :reaction_added,
                 value: "eyes",
                 actor_ref: "UALICE",
                 source: "slack",
                 source_ref: "slack-event:Ev-order-#{second}",
                 occurred_at: DateTime.add(@now, second, :second),
                 request: {:episode, episode.id}
               })
    end

    assert Enum.map(Feedback.for_request({:episode, episode.id}), & &1.source_ref) ==
             Enum.map(1..5, &"slack-event:Ev-order-#{&1}")

    assert Enum.map(Feedback.for_request({:episode, episode.id}, 2), & &1.source_ref) ==
             ["slack-event:Ev-order-4", "slack-event:Ev-order-5"]

    assert Feedback.for_request({:input, Ecto.UUID.generate()}) == []
  end

  defp episode! do
    episode_id = Ecto.UUID.generate()

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: "feedback-store:#{episode_id}",
                 native_input_id: "feedback-store:#{episode_id}",
                 occurred_at: @now,
                 turn_ref: "turn:feedback-store:#{episode_id}"
               })
             )

    transition.episode
  end

  defp input!(text, ts) do
    {:ok, input} =
      SlackInput.new(%{
        actor: %{kind: :user, ref: "UALICE"},
        channel_ref: "CFEEDBACKSTORE",
        content: %{"text" => text},
        event_kind: :message,
        event_ref: "Ev-#{ts}",
        message_ref: ts,
        occurred_at: @now,
        revision: 1,
        thread_ref: nil,
        workspace_ref: @workspace
      })

    {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end
end
