defmodule Ryker.Learning.FleetSessionTest do
  use Ryker.DataCase, async: false
  alias Ryker.Fixtures.Learning, as: Fixtures
  alias Ryker.Learning
  alias Ryker.Learning.FleetSession
  alias Ryker.Repo
  alias Ryker.Work.Session

  test "a learning session owns no episode repository workspace or action authority" do
    entries = Fixtures.inputs!()

    assert {:ok, run} =
             Learning.prepare(Enum.map(entries, & &1.id), %{
               policy: "recorded-read-only-policy",
               policy_digest: String.duplicate("a", 64)
             })

    assert {:ok, session} = FleetSession.ensure(run)
    assert session.execution_kind == :learning
    assert session.learning_run_id == run.id
    assert session.external_ref == "ryker-learning:#{run.id}"

    for field <- [
          :episode_id,
          :admission_input_id,
          :repository_ref,
          :repository_context,
          :workspace_task,
          :authority_digest
        ],
        do: assert(is_nil(Map.fetch!(session, field)))

    assert {:ok, ^session} = FleetSession.ensure(run)
    assert Repo.aggregate(Session, :count) == 1
    assert {:ok, bound} = FleetSession.bind(run, "host-contract-remote-session")
    assert bound.coop_session_id == "host-contract-remote-session"
    assert FleetSession.bind(run, "other") == {:error, :learning_session_identity_conflict}
    assert bound.cleanup_status == :active
    assert {:ok, ^bound} = FleetSession.ensure(run)
  end

  # Each learning step makes sure of its session, and each one announced the
  # session as changed, so every page that lists sessions redrew though
  # nothing had, as self-analysis did until 2026-10-04 (fixed for learning
  # 2026-10-08).
  test "a learning run's session is announced when it is made, not each time a step finds it" do
    entries = Fixtures.inputs!()

    assert {:ok, run} =
             Learning.prepare(Enum.map(entries, & &1.id), %{
               policy: "recorded-read-only-policy",
               policy_digest: String.duplicate("a", 64)
             })

    :ok = Ryker.Work.Custody.subscribe_sessions()

    assert {:ok, session} = FleetSession.ensure(run)
    session_id = session.id
    assert_received {:work_session_updated, ^session_id}

    assert {:ok, %{id: ^session_id}} = FleetSession.ensure(run)
    refute_received {:work_session_updated, ^session_id}
  end
end
