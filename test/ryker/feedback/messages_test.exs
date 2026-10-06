defmodule Ryker.Feedback.MessagesTest do
  @moduledoc """
  What a person's next message says about Ryker's answer, read as the
  message is received. Andrew, 2026-09-27, asked for "feedbacks … and data
  collection" from every answer; a person asking the same thing again, or
  changing their question after the answer, is the plainest feedback there
  is, and nobody has to press anything for it.
  """
  use Ryker.DataCase, async: true
  alias Ryker.Feedback
  alias Ryker.Feedback.Messages
  alias Ryker.Fixtures.Answers
  alias Ryker.Ingress.Inbox

  @workspace "TFEEDBACKMESSAGES"
  @channel "CFEEDBACKMESSAGES"

  # One conversation per test keeps the async suites off each other's locks.
  setup do
    %{channel: "#{@channel}#{System.unique_integer([:positive])}"}
  end

  test "asking the same thing again soon after the answer is feedback on the request that answered",
       %{channel: channel} do
    question = message!(channel, "Is checkout up?", "1790000000.000100")

    reply =
      Answers.work_reply!(
        question,
        "Checkout is up.",
        "1790000060.000100",
        at("1790000060.000100")
      )

    # Asked again at the top of the channel, a minute after the answer.
    again = message!(channel, "is checkout up??", "1790000120.000100")

    assert [signal] = Feedback.for_request({:episode, reply.episode.id})

    assert {signal.kind, signal.category, signal.value} == {:asked_again, :asked_again, nil}

    assert {signal.actor_ref, signal.source, signal.source_ref, signal.occurred_at} ==
             {"UALICE", "slack", Inbox.ref(again), again.occurred_at}
  end

  test "a question routing answered by itself is the request asked again", %{channel: channel} do
    question = message!(channel, "What's the status of the deploy?", "1790000200.000100")

    Answers.quick_reply!(
      question,
      "It finished at 10:02.",
      "1790000205.000100",
      at("1790000205.000100")
    )

    again =
      message!(channel, "status of the deploy?", "1790000260.000100",
        thread: question.destination_thread_ref
      )

    assert [%{kind: :asked_again, source_ref: source_ref}] =
             Feedback.for_request({:input, question.id})

    assert source_ref == Inbox.ref(again)
  end

  # Conservative on purpose: a false "asked again" sends someone to look for a
  # problem in an answer that was fine.
  test "a new message is not asking again unless the same person repeats it soon, in the same place",
       %{channel: channel} do
    question = message!(channel, "Is checkout up?", "1790000300.000100")
    thread = question.destination_thread_ref

    reply =
      Answers.work_reply!(
        question,
        "Checkout is up.",
        "1790000310.000100",
        at("1790000310.000100")
      )

    # A different question, someone else asking, a reply in another thread,
    # and a greeting are not asking again.
    message!(channel, "Is checkout down?", "1790000320.000100", thread: thread)
    message!(channel, "Is checkout up?", "1790000330.000100", thread: thread, actor: "UBOB")
    message!(channel, "Is checkout up?", "1790000340.000100", thread: "1790000001.000100")

    # Eleven minutes after the answer is not soon.
    message!(channel, "Is checkout up?", "1790000971.000100", thread: thread)

    assert Feedback.for_request({:episode, reply.episode.id}) == []

    # A question nobody answered yet cannot be asked again.
    pending = message!(channel, "Why is billing slow?", "1790001000.000100")

    message!(channel, "why is billing slow", "1790001030.000100",
      thread: pending.destination_thread_ref
    )

    greeting = message!(channel, "hi", "1790001100.000100")

    Answers.quick_reply!(
      greeting,
      "Hi! How can I help?",
      "1790001101.000100",
      at("1790001101.000100")
    )

    message!(channel, "hi", "1790001110.000100", thread: greeting.destination_thread_ref)

    assert Feedback.for_request({:input, pending.id}) == []
    assert Feedback.for_request({:input, greeting.id}) == []
  end

  test "editing or deleting a message after Ryker answered it is feedback, and before is not",
       %{channel: channel} do
    question = message!(channel, "Is checkout up?", "1790002000.000100")

    # Fixing a typo before the answer is not feedback on it.
    message!(channel, "Is checkout up yet?", "1790002000.000100",
      kind: :edit,
      revision: 2,
      at: at("1790002030.000100")
    )

    reply =
      Answers.work_reply!(
        question,
        "Checkout is up.",
        "1790002060.000100",
        at("1790002060.000100")
      )

    assert Feedback.for_request({:episode, reply.episode.id}) == []

    edited =
      message!(channel, "Is checkout up in eu-west?", "1790002000.000100",
        kind: :edit,
        revision: 3,
        at: at("1790002120.000100")
      )

    deleted =
      message!(channel, "Is checkout up in eu-west?", "1790002000.000100",
        kind: :delete,
        revision: 4,
        at: at("1790002200.000100")
      )

    assert [
             %{kind: :message_edited, category: :edited, source_ref: edited_ref},
             %{kind: :message_deleted, category: :edited, source_ref: deleted_ref}
           ] = Feedback.for_request({:episode, reply.episode.id})

    assert {edited_ref, deleted_ref} == {Inbox.ref(edited), Inbox.ref(deleted)}
  end

  # Slack reports a link's preview arriving as an edit with the words
  # untouched, and it counted as the person editing their question after the
  # answer, which costs an analysis (2026-10-04 review).
  test "a link preview arriving after the answer is no feedback", %{channel: channel} do
    question = message!(channel, "Is https://checkout.example.com up?", "1790003000.000100")

    reply =
      Answers.work_reply!(
        question,
        "Checkout is up.",
        "1790003060.000100",
        at("1790003060.000100")
      )

    message!(channel, "Is https://checkout.example.com up?", "1790003000.000100",
      kind: :edit,
      revision: 2,
      at: at("1790003120.000100")
    )

    assert Feedback.for_request({:episode, reply.episode.id}) == []
  end

  test "editing a message routing answered by itself is feedback on that message",
       %{channel: channel} do
    question = message!(channel, "What's our on-call rota?", "1790003000.000100")

    Answers.quick_reply!(
      question,
      "I don't know it yet.",
      "1790003002.000100",
      at("1790003002.000100")
    )

    message!(channel, "What's our on-call rota this week?", "1790003000.000100",
      kind: :edit,
      revision: 2,
      at: at("1790003040.000100")
    )

    assert [%{kind: :message_edited}] = Feedback.for_request({:input, question.id})
  end

  test "an app's message says nothing about an answer", %{channel: channel} do
    question =
      message!(channel, "Deploy 42 failed", "1790004000.000100", actor: "B0APP", actor_kind: :app)

    reply =
      Answers.work_reply!(
        question,
        "Looking into deploy 42.",
        "1790004010.000100",
        at("1790004010.000100")
      )

    message!(channel, "Deploy 42 failed", "1790004020.000100", actor: "B0APP", actor_kind: :app)
    assert Feedback.for_request({:episode, reply.episode.id}) == []
  end

  describe "repeating a question" do
    test "reads the same, uses the same words, or shares most meaningful words" do
      for {earlier, later} <- [
            {"Is checkout up?", "is checkout up??"},
            {"<@U0RYKER> Is checkout up?", "is checkout up"},
            {"Is checkout up?", "is checkout up now?"},
            {"What's the status of the deploy?", "status of the deploy?"},
            {"Why does checkout return 502 errors since this morning?",
             "why is checkout returning 502 errors since this morning"},
            {"Проверь статус деплоя", "проверь статус деплоя!"}
          ] do
        assert Messages.repeats?(Messages.words(earlier), Messages.words(later)),
               "expected #{inspect(later)} to repeat #{inspect(earlier)}"
      end
    end

    test "never counts a different question, a greeting or a thanks" do
      for {earlier, later} <- [
            {"Is checkout up?", "Is checkout down?"},
            {"Status of the deploy?", "Status of the database?"},
            {"hi", "hi"},
            {"thanks!", "thanks"},
            {"Why is checkout slow?", "When is checkout slow?"},
            {"", ""}
          ] do
        refute Messages.repeats?(Messages.words(earlier), Messages.words(later)),
               "expected #{inspect(later)} not to repeat #{inspect(earlier)}"
      end
    end
  end

  defp message!(channel, text, ts, options \\ []) do
    Answers.slack_message!(
      Keyword.merge(
        [workspace: @workspace, channel: channel, text: text, ts: ts],
        options
      )
    )
  end

  defp at(ts), do: Answers.slack_time(ts)
end
