defmodule Responder.Learning.FleetSessionTest do
  use Responder.DataCase, async: false
  alias Responder.Fixtures.Learning, as: Fixtures
  alias Responder.Learning.FleetSession
  alias Responder.Repo
  alias Responder.State.Learning
  alias Responder.Work.Session

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
    assert session.external_ref == "responder-learning:#{run.id}"

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
    assert {:error, :learning_session_identity_conflict} = FleetSession.bind(run, "other")
    assert bound.cleanup_status == :active
    assert {:ok, ^bound} = FleetSession.ensure(run)
  end
end
