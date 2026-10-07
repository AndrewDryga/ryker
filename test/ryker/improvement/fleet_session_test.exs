defmodule Ryker.Improvement.FleetSessionTest do
  use Ryker.DataCase, async: true
  alias Ryker.Feedback
  alias Ryker.Fixtures.Answers
  alias Ryker.Improvement.{AnalysisRun, FleetSession}
  alias Ryker.Inspectors
  alias Ryker.Work.Custody

  @workspace "TIMPROVEFLEETSESSION"
  @now ~U[2026-09-27 12:00:00.000000Z]

  # Each analysis step makes sure of its session, every two seconds while a
  # run is out, and each step announced the session as changed, so every
  # page that lists sessions redrew though nothing had (2026-10-04 review).
  test "an analysis run's session is announced when it is made, not each time a step finds it" do
    run = run!("1790500100.000100")
    :ok = Custody.subscribe_sessions()

    assert {:ok, session} = FleetSession.ensure(run)
    session_id = session.id
    assert_received {:work_session_updated, ^session_id}

    assert {:ok, %{id: ^session_id}} = FleetSession.ensure(run)
    refute_received {:work_session_updated, ^session_id}
  end

  defp run!(ts) do
    question =
      Answers.slack_message!(
        workspace: @workspace,
        channel: "CFLEET",
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

    assert {:ok, _recorded} =
             Feedback.record(%{
               kind: :reaction_added,
               value: "-1",
               actor_ref: "UALICE",
               source: "slack",
               source_ref: "slack-event:fleet-#{ts}",
               occurred_at: @now,
               request: {:episode, reply.episode.id}
             })

    candidate = Inspectors.improvement_candidate({:episode, reply.episode.id})

    Repo.insert!(%AnalysisRun{
      id: Ecto.UUID.generate(),
      candidate_id: candidate.id,
      generation: 1,
      status: :prepared,
      policy: "ryker-learning",
      policy_digest: String.duplicate("a", 64),
      prompt: ~s({"instructions":"Diagnose.","context":{}}),
      prompt_sha256: String.duplicate("b", 64),
      output_schema: %{"type" => "object"},
      manifest: %{},
      inserted_at: @now,
      updated_at: @now
    })
  end
end
