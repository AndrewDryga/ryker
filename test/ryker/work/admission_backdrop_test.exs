defmodule Ryker.Work.AdmissionBackdropTest do
  use Ryker.DataCase, async: true

  alias Ryker.Admission
  alias Ryker.Admission.Decision
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

  defp admit!(entry, :start) do
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
      Decision.parse(%{
        "action" => "start_episode",
        "episode_ref" => nil,
        "reaction" => nil,
        "relation" => "unrelated",
        "reason" => "This needs investigation.",
        "repository_source" => nil,
        "work_class" => "standard"
      })

    Admission.commit(context, decision, "backdrop-test:#{entry.id}", lease_ref: lease_ref)
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
        workspace_ref: "TROUTE"
      })

    {:ok, %{entry: entry}} = Inbox.record(input)
    entry
  end

  defp slack_time(ts) do
    {seconds, _rest} = Float.parse(ts)
    seconds |> Kernel.*(1_000_000) |> round() |> DateTime.from_unix!(:microsecond)
  end
end
