defmodule Ryker.Work.BackgroundSentPromptsMigrationTest do
  @moduledoc """
  A session with no activity owner, a learning, self-analysis or
  repository-reading session, keeps the records of what its worker sent and
  nothing else. Rolling back refuses while one is kept.
  """
  # The migrator runs inside this test's sandbox transaction.
  use Ryker.MigrationCase
  alias Ryker.Fixtures.Learning, as: LearningFixtures
  alias Ryker.Learning
  alias Ryker.Learning.FleetSession
  alias Ryker.Work.ActivityEvent

  @version 20_261_016_120_000

  test "a session with no owner keeps a record of what was sent, and rollback refuses while it does" do
    session = learning_session!()
    assert {:ok, _sent} = insert(session, "prompt.sent")

    assert_raise Postgrex.Error, ~r/still keep what their workers sent/, fn ->
      migrate_down(@version)
    end
  end

  test "a session with no owner keeps no narration" do
    assert {:error, changeset} = insert(learning_session!(), "tool.started")

    assert {_message, [constraint: :check, constraint_name: "activity_owner_valid"]} =
             changeset.errors[:episode_id]
  end

  test "rolled back, a session with no owner keeps nothing" do
    session = learning_session!()
    assert migrate_down(@version) == :ok
    assert {:error, changeset} = insert(session, "prompt.sent")
    assert changeset.errors[:episode_id]
  end

  defp learning_session! do
    {:ok, run} =
      Learning.prepare(Enum.map(LearningFixtures.inputs!(), & &1.id), %{
        policy: "recorded-read-only-policy",
        policy_digest: String.duplicate("a", 64)
      })

    {:ok, _session} = FleetSession.ensure(run)
    {:ok, session} = FleetSession.bind(run, "coop-sent-migration")
    session
  end

  defp insert(session, kind) do
    payload = %{"unreadable" => true}

    %{
      session_id: session.id,
      remote_session_id: "coop-sent-migration",
      remote_event_id: "event-1",
      coop_turn_id: "coop-turn-1",
      kind: kind,
      sequence: 1,
      version: 1,
      occurred_at: DateTime.utc_now(),
      payload: payload,
      payload_fingerprint: Ryker.CanonicalJSON.digest(payload)
    }
    |> ActivityEvent.Changeset.insert()
    |> Repo.insert()
  end
end
