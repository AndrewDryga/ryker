defmodule Ryker.Improvement.CandidatesTest do
  use Ryker.DataCase, async: true

  import Ecto.Query

  alias Ryker.Feedback
  alias Ryker.Fixtures.Answers
  alias Ryker.Improvement
  alias Ryker.Improvement.Candidate

  @workspace "TIMPROVECANDIDATES"
  @now ~U[2026-09-27 12:00:00.000000Z]

  # Andrew, 2026-09-27: a request people were unhappy with should become an
  # eval case "without much of manual human reviews". The loop only starts if
  # every kind of negative feedback reaches it, and it stays cheap only if
  # nothing positive or neutral does: each candidate costs one model call.
  test "each kind of negative feedback makes its request a candidate, and nothing else does" do
    negative = [
      {:sentiment, "frustrated", nil, "frustrated"},
      {:sentiment, "angry", nil, "frustrated"},
      {:reaction_added, "-1", nil, "reaction"},
      {:reaction_added, "thumbsdown", nil, "reaction"},
      {:reaction_added, "face_with_rolling_eyes", nil, "reaction"},
      {:asked_again, nil, nil, "asked_again"},
      {:message_edited, nil, nil, "edited"},
      {:message_deleted, nil, nil, "edited"},
      {:reviewed, "cancelled", "Stopped: it checked production.", "stopped"}
    ]

    for {{kind, value, note, reason}, index} <- Enum.with_index(negative) do
      request = work_request!("1790000#{100 + index}.000100")
      record!(request, kind, value, note, "negative-#{index}")

      assert %Candidate{reasons: [^reason], signal_count: 1, status: :open, analysis: :pending} =
               Improvement.for_request(request),
             "#{kind} #{inspect(value)} should make a candidate"
    end

    positive_or_neutral = [
      {:sentiment, "satisfied", nil},
      {:sentiment, "neutral", nil},
      {:reaction_added, "+1", nil},
      {:reaction_added, "eyes", nil},
      # Sad faces are as often about the news an answer carried as about the
      # answer, so the Feedback page's frustrated list is not the rule here.
      {:reaction_added, "cry", nil},
      {:reaction_removed, "-1", nil},
      {:reviewed, "complete", "Checked."}
    ]

    for {{kind, value, note}, index} <- Enum.with_index(positive_or_neutral) do
      request = work_request!("1790001#{100 + index}.000100")
      record!(request, kind, value, note, "other-#{index}")

      assert Improvement.for_request(request) == nil,
             "#{kind} #{inspect(value)} should not make a candidate"
    end
  end

  # Slack redelivers events and routing can commit a decision twice; a person
  # who reacts, asks again and then says they are annoyed is one unhappy
  # request, analyzed once, not three.
  test "a request is one candidate however much negative feedback it gets, and a redelivery counts once" do
    request = work_request!("1790002100.000100")

    record!(request, :reaction_added, "-1", nil, "burst-1", @now)
    record!(request, :asked_again, nil, nil, "burst-2", DateTime.add(@now, 60, :second))
    record!(request, :asked_again, nil, nil, "burst-2", DateTime.add(@now, 90, :second))

    record!(
      request,
      :sentiment,
      "angry",
      "They say it looked at production again.",
      "burst-3",
      DateTime.add(@now, 120, :second)
    )

    # Positive feedback on the same request never adds to it.
    record!(request, :reaction_added, "+1", nil, "burst-4", DateTime.add(@now, 200, :second))

    assert [candidate] =
             Repo.all(
               from(candidate in Candidate, where: candidate.episode_id == ^elem(request, 1))
             )

    assert candidate.reasons == ["asked_again", "frustrated", "reaction"]
    assert candidate.signal_count == 3
    assert candidate.first_signal_at == @now
    assert candidate.last_signal_at == DateTime.add(@now, 120, :second)
  end

  test "a quick reply routing sent by itself is a request of its own" do
    question =
      Answers.slack_message!(
        workspace: @workspace,
        channel: "COPS",
        text: "Count to 10",
        ts: "1790003100.000100"
      )

    Answers.quick_reply!(
      question,
      "1, 2, 3.",
      "1790003105.000100",
      DateTime.add(@now, 5, :second)
    )

    record!({:input, question.id}, :reaction_added, "x", nil, "quick-1")

    assert %Candidate{episode_id: nil, input_id: input_id, request_ref: ref, transport: "slack"} =
             Improvement.for_request({:input, question.id})

    assert input_id == question.id
    assert ref == "ingress-input:" <> question.id
  end

  # The candidate is written in the transaction that records the signal: a
  # rolled-back signal leaves no candidate, and one is announced only once it
  # has committed, so the analysis worker never wakes for a row it cannot read.
  test "a candidate commits and is announced with its signal, and never without it" do
    request = work_request!("1790004100.000100")
    :ok = Improvement.subscribe_improvement()

    # The topic is shared by every test that records feedback, so each
    # announcement is looked for by the candidate it names.
    assert {:error, {:rolled_back, rolled_back}} =
             Repo.transaction(fn ->
               {:ok, _recorded} = Feedback.record_in_transaction(attributes(request, "rolled"))
               Repo.rollback({:rolled_back, Improvement.for_request(request).id})
             end)

    assert Improvement.for_request(request) == nil
    refute_received {:improvement_updated, ^rolled_back}

    assert {:ok, _recorded} = Feedback.record(attributes(request, "kept"))
    %Candidate{id: id} = Improvement.for_request(request)
    assert_received {:improvement_updated, ^id}
  end

  defp work_request!(ts) do
    question =
      Answers.slack_message!(
        workspace: @workspace,
        channel: "COPS",
        text: "Is the staging database healthy?",
        ts: ts
      )

    reply =
      Answers.work_reply!(
        question,
        "The production database is healthy.",
        String.replace(ts, ".000100", ".000200"),
        DateTime.add(@now, 30, :second)
      )

    {:episode, reply.episode.id}
  end

  defp record!(request, kind, value, note, event, at \\ @now) do
    assert {:ok, _recorded} =
             Feedback.record(%{
               kind: kind,
               value: value,
               note: note,
               actor_ref: "UALICE",
               source: "slack",
               source_ref: "slack-event:#{event}",
               occurred_at: at,
               request: request
             })
  end

  defp attributes(request, event),
    do: %{
      kind: :reaction_added,
      value: "-1",
      actor_ref: "UALICE",
      source: "slack",
      source_ref: "slack-event:#{event}",
      occurred_at: @now,
      request: request
    }
end
