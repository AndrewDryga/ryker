defmodule Ryker.RepositoryKnowledge.FleetSessionTest do
  use Ryker.DataCase, async: true
  alias Ryker.RepositoryKnowledge.{Entry, FleetSession, Run}
  alias Ryker.Work.Custody

  @now ~U[2026-10-08 09:00:00.000000Z]

  # Each step of a knowledge run makes sure of its session, every few seconds
  # while a run is out, and each step announced the session as changed, so
  # every page that lists sessions redrew though nothing had. Self-analysis
  # stopped this on 2026-10-04; repository reading kept the copy it had been
  # written from until 2026-10-08.
  test "a knowledge run's session is announced when it is made, not each time a step finds it" do
    run = run!()
    :ok = Custody.subscribe_sessions()

    assert {:ok, session} = FleetSession.ensure(run)
    session_id = session.id
    assert_received {:work_session_updated, ^session_id}

    assert {:ok, %{id: ^session_id}} = FleetSession.ensure(run)
    refute_received {:work_session_updated, ^session_id}
  end

  defp run! do
    Repo.insert!(%Entry{repository_ref: "fleet-session"})

    Repo.insert!(%Run{
      repository_ref: "fleet-session",
      generation: 1,
      status: :prepared,
      source_commit: String.duplicate("a", 40),
      policy: "ryker-repo-standard",
      policy_digest: String.duplicate("b", 64),
      transport: "github",
      conversation_ref: "github:fleet-session:repository:1",
      prompt: ~s({"instructions":"Read the repository.","context":{}}),
      prompt_sha256: String.duplicate("c", 64),
      output_schema: %{"type" => "object"},
      manifest: %{},
      inserted_at: @now,
      updated_at: @now
    })
  end
end
