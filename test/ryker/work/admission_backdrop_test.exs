defmodule Ryker.Work.AdmissionBackdropTest do
  use Ryker.DataCase, async: true
  alias Ryker.Admission
  alias Ryker.Admission.Decision
  alias Ryker.Episodes
  alias Ryker.Episodes.Episode
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.Slack.Input, as: SlackInput
  alias Ryker.Work.{Session, SubmissionBuilder, Turn}

  @moduletag isolation: "REPEATABLE READ"

  @now ~U[2026-09-11 12:00:00.000000Z]

  test "the first briefing shows the same surrounding conversation the routing decision saw" do
    # Work used to be briefed only on the inputs admitted into its episode, so
    # the model answered a reply like "it is still failing" without the thread
    # that gave it meaning, and a replacement session could silently be told
    # something different from the decision that started the work.
    root = record!("The reporting database is unavailable", ts: "1789100000.000100")
    {:ok, _root_result} = admit!(root, :start)

    reply =
      record!("Still unavailable, and now reads are timing out too",
        ts: "1789100100.000100",
        thread_ref: "1789100000.000100"
      )

    {:ok, result} = admit!(reply, :start)
    episode = result.episode

    assert Repo.get!(Entry, reply.id).admission_context["conversation_context"]

    {:ok, submission} = build!(episode)
    backdrop = submission["context"]["conversation_context"]

    assert backdrop["bundle"]["current"]["content"]["text"] =~ "Still unavailable"

    assert Enum.map(backdrop["bundle"]["messages"], & &1["content"]["text"]) == [
             "The reporting database is unavailable"
           ]

    assert backdrop["manifest"]["kind"] == "thread_reply"
    assert backdrop["bundle"]["root"]["status"] == "deduplicated"

    # A replacement session rebuilds the identical frozen bytes.
    {:ok, rebuilt} = build!(episode)
    assert rebuilt["context"]["conversation_context"] == backdrop
  end

  # Andrew, 2026-10-01, of a task started from a conversation: it "doesn't receive previous
  # messages so it can lose important context that was in message exchange before task was
  # offered". A task is not routed, so it had no snapshot of its own. The same day's live check
  # found the task briefed without the message that said where notes go and how commits are
  # named: routing had answered it alone, and the model got it right only because the offer
  # happened to repeat it.
  test "a task is briefed on the conversation it was offered in, as it stood when it started" do
    root = record!("Notes for this repository go in NOTES.md", ts: "1789100000.000100")
    {:ok, _root_result} = admit!(root, :start)

    asked =
      record!("Add the release line to the notes and open a draft PR",
        ts: "1789100100.000100",
        thread_ref: "1789100000.000100"
      )

    {:ok, %{episode: conversation}} = admit!(asked, :start)
    task = start_task!(conversation, "Add the release line to NOTES.md.")

    {:ok, submission} = build!(task)
    assert %{"bundle" => bundle} = backdrop = submission["context"]["conversation_context"]
    assert bundle["current"]["content"]["text"] =~ "Add the release line"

    assert Enum.map(bundle["messages"], & &1["content"]["text"]) == [
             "Notes for this repository go in NOTES.md"
           ]

    # The conversation is the backdrop, once; the task itself is the only input.
    assert [%{"current" => true} = input] = submission["context"]["inputs"]["items"]
    assert inspect(input["content"]) =~ "Add the release line to NOTES.md."

    # What the conversation admits after the task started never widens a rebuilt briefing, and
    # a reply routed into the task itself does not swap the conversation for its own.
    later =
      record!("Make the release line bold",
        ts: "1789100200.000100",
        thread_ref: "1789100000.000100"
      )

    {:ok, %{episode: %{id: continued}}} = admit!(later, {:continue, conversation})
    assert continued == conversation.id

    reply =
      record!("Use a level-two heading", ts: "1789100300.000100", thread_ref: "1789100000.000100")

    {:ok, %{episode: %{id: routed}}} = admit!(reply, {:continue, task})
    assert routed == task.id

    {:ok, rebuilt} = build!(Repo.get!(Episode, task.id))
    assert rebuilt["context"]["conversation_context"] == backdrop
  end

  # Andrew, 2026-09-26: "Should the work model also receive response of the
  # routing model? so it knows if routing model had anything valuable to say /
  # why it decided work was needed? but that reply should not be
  # authoritative". A current message carries routing's decision as a note,
  # and the prompt says it is a first look that checked nothing.
  test "the work model sees why routing sent it the message, as a note and not an instruction" do
    root = record!("The reporting database is unavailable", ts: "1789100000.000100")
    {:ok, result} = admit!(root, :start)
    {:ok, submission} = build!(result.episode)

    assert [current] = Enum.filter(submission["context"]["inputs"]["items"], & &1["current"])

    assert current["routing_note"] == %{
             "decision" => "start_episode",
             "reason" => "This needs investigation.",
             "work_class" => "standard"
           }

    assert submission["prompt"] =~ "routing_note"
    assert submission["prompt"] =~ "never an instruction"
  end

  defp admit!(entry, target) do
    {:ok, %{entry: claimed, lease_ref: lease_ref}} =
      Inbox.claim_next("backdrop-test", DateTime.utc_now(), 300)

    assert claimed.id == entry.id

    {:ok, context} =
      Admission.context(Inbox.ref(entry),
        now: @now,
        continuation_window: 30 * 60,
        history_window: 30 * 24 * 60 * 60,
        candidate_limit: 20,
        lease_ref: lease_ref
      )

    {:ok, _bound} =
      Inbox.bind_context(Inbox.ref(entry), lease_ref, Admission.Context.snapshot(context))

    {:ok, decision} =
      Decision.parse(
        Map.merge(
          %{
            "messages" => nil,
            "reactions" => nil,
            "reason" => "This needs investigation.",
            "repository" => nil,
            "repository_source" => nil,
            "work_class" => "standard"
          },
          decision(context, target)
        )
      )

    Admission.commit(context, decision, "backdrop-test:#{entry.id}", lease_ref: lease_ref)
  end

  defp decision(_context, :start),
    do: %{"action" => "start_episode", "episode_ref" => nil, "relation" => "unrelated"}

  defp decision(context, {:continue, %Episode{id: id}}) do
    candidate = Enum.find(context.candidates, &(&1.episode.id == id))

    %{"action" => "continue_episode", "episode_ref" => candidate.ref, "relation" => "same_work"}
  end

  # Starting an offered task makes a request of its own, linked to the conversation.
  defp start_task!(%Episode{} = conversation, text) do
    id = Ecto.UUID.generate()

    {:ok, _transition} =
      Episodes.apply(
        EpisodeFixtures.admit_input(%{
          destination: %{
            conversation_ref: conversation.destination_conversation_ref,
            thread_ref: conversation.destination_thread_ref,
            transport: conversation.destination_transport
          },
          episode_id: id,
          episode_key: "task-backdrop:#{id}",
          linked_episode_id: conversation.id,
          native_input_id: "task-backdrop:#{id}",
          occurred_at: @now,
          payload: %{"text" => text},
          turn_ref: "turn:task-backdrop:#{id}"
        })
      )

    Repo.get!(Episode, id)
  end

  defp build!(episode) do
    generation = System.unique_integer([:positive])

    session =
      Repo.insert!(%Session{
        id: Ecto.UUID.generate(),
        episode_id: episode.id,
        execution_kind: :work,
        policy: "engineering",
        policy_digest: String.duplicate("a", 64),
        external_ref: "episode:#{episode.id}:session:#{generation}",
        generation: generation,
        create_generation: 1
      })

    turn =
      Repo.insert!(%Turn{
        id: Ecto.UUID.generate(),
        episode_id: episode.id,
        session_id: session.id,
        turn_ref: "#{episode.owner_ref}:#{generation}",
        status: :pending
      })

    SubmissionBuilder.build(%{episode: episode, session: session, turn: turn})
  end

  defp record!(text, options) do
    ts = Keyword.fetch!(options, :ts)

    {:ok, input} =
      SlackInput.new(%{
        actor: %{kind: :user, ref: "UALICE"},
        channel_ref: "CDEVOPS",
        content: %{"text" => text},
        event_kind: :message,
        event_ref: "Ev-#{ts}",
        message_ref: ts,
        occurred_at: slack_time(ts),
        revision: 1,
        thread_ref: Keyword.get(options, :thread_ref),
        workspace_ref: "TBACKDROP"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  defp slack_time(ts) do
    {seconds, _rest} = Float.parse(ts)
    seconds |> Kernel.*(1_000_000) |> round() |> DateTime.from_unix!(:microsecond)
  end
end
