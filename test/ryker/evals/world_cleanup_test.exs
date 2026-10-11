defmodule Ryker.Evals.WorldCleanupTest do
  use Ryker.DataCase, async: false
  alias Ryker.Episodes
  alias Ryker.Evals.{SessionCleanup, WorldDatabase}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.TestSupport.FakeWorkCoopAPI
  alias Ryker.Work.{Dispatcher, Session, Turn}

  defmodule RunningAPI do
    defdelegate capabilities(client), to: FakeWorkCoopAPI
    defdelegate operation_by_key(client, key), to: FakeWorkCoopAPI
    defdelegate prepare_create_session(client, key, policy, task, source), to: FakeWorkCoopAPI
    defdelegate create_session(client, key, policy, task, source), to: FakeWorkCoopAPI
    defdelegate get_session(client, session), to: FakeWorkCoopAPI
    defdelegate get_turn(client, session, turn), to: FakeWorkCoopAPI
    defdelegate list_events(client, session, cursor, limit), to: FakeWorkCoopAPI
    defdelegate close_session(client, session, key, revision), to: FakeWorkCoopAPI

    def cancel_turn(client, session, turn, key, revision) do
      case FakeWorkCoopAPI.state(client)[:cancel_error] do
        nil -> FakeWorkCoopAPI.cancel_turn(client, session, turn, key, revision)
        reason -> {:error, reason}
      end
    end

    def submit_frozen_turn(client, session, key, revision, submission, binding, artifacts) do
      {:ok, response} =
        FakeWorkCoopAPI.submit_frozen_turn(
          client,
          session,
          key,
          revision,
          submission,
          binding,
          artifacts
        )

      # This is runtime state, not an invented model answer: no answer exists yet.
      running = response["turn"] |> Map.put("state", "running") |> Map.put("candidate", nil)
      FakeWorkCoopAPI.update(client, &%{&1 | turn: running})
      {:ok, %{response | "turn" => running}}
    end
  end

  setup do
    # Six paid campaign observations retained active owners after runtime failure on
    # 2026-10-11. Cancelling waits alone left those workspaces held and cleanup incomplete.
    command = EpisodeFixtures.admit_input(%{occurred_at: Repo.now!()})
    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             WorkSessions.pin_episode(
               command.episode_id,
               "world-eval-read-only",
               String.duplicate("a", 64)
             )

    captured =
      "testdata/work/terraform-automation-recovery.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("accepted_candidate")

    candidates = [Jason.encode!(captured)]

    assert {:ok, client} =
             FakeWorkCoopAPI.start_link(candidates, lose_first_cancel_response: true)

    executor = [api: RunningAPI, client: client, max_polls: 1, poll_interval_ms: 0]
    work = [executor_options: executor, lease_seconds: 120, worker_ref: "world-cleanup:prepare"]

    assert Dispatcher.run_once(work) == {:ok, {:deferred, {:work_poll_window_elapsed, :turn}}}
    assert [%Turn{status: :pending} = turn] = Repo.all(Turn)
    assert [%Session{} = session] = Repo.all(Session)
    assert is_binary(turn.coop_turn_id)
    assert is_binary(session.coop_session_id)
    assert FakeWorkCoopAPI.state(client).submit_count == 1

    %{command: command, client: client, work: work, turn: turn, session: session}
  end

  test "failed world cleanup stops its exact active turn without erasing the failure", %{
    command: command,
    client: client,
    work: work,
    turn: turn,
    session: session
  } do
    assert WorldDatabase.request_episode_cancellation() == :ok
    assert Repo.fetch!(Turn.Query.by_id(turn.id)).status == :cancel_pending

    # The owner and report rows survive until the worker actually confirms the stop.
    assert Repo.fetch!(Episodes.Episode.Query.by_id(command.episode_id)).owner_ref ==
             turn.turn_ref

    assert WorldDatabase.request_episode_cancellation() == :ok

    assert SessionCleanup.drain_work(Keyword.put(work, :worker_ref, "world-cleanup:stop"), 16) ==
             :ok

    assert Repo.fetch!(Episodes.Episode.Query.by_id(command.episode_id)).state == :cancelled
    assert Repo.fetch!(Turn.Query.by_id(turn.id)).status == :superseded
    state = FakeWorkCoopAPI.state(client)
    assert state.submit_count == 1
    assert length(state.cancel_keys) == 1
    assert state.session["state"] == "closed"

    assert {:ok, retention} = Ryker.FakeRetentionCoopAPI.start_link(sessions: [state.session])

    retention_options = [
      api: Ryker.FakeRetentionCoopAPI,
      client: retention,
      worker_ref: "world-cleanup:discard"
    ]

    assert SessionCleanup.drain(retention_options, 16) == :ok
    assert Repo.fetch!(Session.Query.by_id(session.id)).cleanup_status == :discarded
    assert Repo.aggregate(Turn, :count) == 1
  end

  test "an unreachable cleanup holder keeps its owner and the failed world database", %{
    command: command,
    client: client,
    work: work,
    turn: turn,
    session: session
  } do
    FakeWorkCoopAPI.update(
      client,
      &Map.put(&1, :cancel_error, {:coop_unavailable, :holder_offline})
    )

    assert WorldDatabase.request_episode_cancellation() == :ok

    cleanup = fn -> SessionCleanup.drain_work(work, 16) end

    result =
      WorldDatabase.run_cleanup({:error, :observed_runtime_failure}, cleanup, fn ->
        send(self(), :local_cleanup_ran)
        :ok
      end)

    assert {:error, {:world_work_cleanup_deferred, _reason}} = result
    refute_received :local_cleanup_ran

    assert Repo.fetch!(Episodes.Episode.Query.by_id(command.episode_id)).owner_ref ==
             turn.turn_ref

    assert Repo.fetch!(Turn.Query.by_id(turn.id)).status == :cancel_pending
    assert Repo.fetch!(Turn.Query.by_id(turn.id)).cancellation_receipt == nil
    refute Repo.fetch!(Session.Query.by_id(session.id)).cleanup_status == :discarded
    assert FakeWorkCoopAPI.state(client).submit_count == 1
    assert FakeWorkCoopAPI.state(client).turn["state"] == "running"
  end
end
