defmodule Responder.Work.CustodyConcurrencyTest do
  use Responder.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Responder.Episodes
  alias Responder.Episodes.{Episode, Event}
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Repo
  alias Responder.Work.{Activity, ActivityEvent, Custody, Session, Turn}

  @now ~U[2026-08-28 12:00:00.000000Z]

  test "simultaneous workers cannot own the same logical turn" do
    # A process crash can release many queued episodes at once. Competing pool
    # workers must converge on one fenced owner without duplicating the turn.
    Sandbox.unboxed_run(Repo, fn ->
      command = create_episode!()
      parent = self()

      contenders =
        Enum.map(1..2, fn index ->
          unboxed_task(fn ->
            send(parent, {:ready, self()})

            receive do
              :claim -> Custody.claim_next("worker:#{index}", 60)
            end
          end)
        end)

      try do
        Enum.each(contenders, fn contender ->
          contender_pid = contender.pid
          assert_receive {:ready, ^contender_pid}, 5_000
        end)

        Enum.each(contenders, &send(&1.pid, :claim))
        results = Enum.map(contenders, &Task.await(&1, 5_000))

        claims = for {:ok, %{turn: claimed}} <- results, do: claimed

        assert length(claims) == 1
        assert Enum.count(results, &(&1 == {:ok, nil})) == 1
        assert Repo.aggregate(Turn, :count) == 1
        assert Repo.aggregate(Session, :count) == 1
      after
        stop_tasks(contenders)
        cleanup(command)
      end
    end)
  end

  test "activity ingestion cannot deadlock a final preflight holding its episode owner" do
    # September 9's concurrent-human-feedback World run returned HTTP 500 from
    # validate_final: activity held Session then waited on its Episode FK while
    # preflight held Episode then waited on Session. The model had to retry.
    # This one-event structural page reproduces those locks without a model call.
    Sandbox.unboxed_run(Repo, fn ->
      command = create_episode!()
      {:ok, claim} = Custody.claim_next("activity-preflight", 60, :work)

      {:ok, session} =
        Custody.bind_session(
          command.episode_id,
          claim.turn.turn_ref,
          claim.lease_ref,
          claim.session.generation,
          claim.session.create_generation,
          "remote:activity-preflight:#{command.episode_id}"
        )

      parent = self()

      preflight = preflight_contender(claim, parent)

      assert_receive {:episode_locked, owner_backend}, 5_000

      activity = activity_contender(session, parent)

      try do
        assert_receive {:activity_backend, activity_backend}, 5_000
        await_blocked_by(activity_backend, owner_backend)
        send(preflight.pid, :preflight)

        assert {:ok, {:ok, %Turn{}}} = Task.await(preflight, 5_000)
        assert {:ok, %{cursor: 1, inserted: 1}} = Task.await(activity, 5_000)
        assert Repo.aggregate(ActivityEvent, :count) == 1
        assert Repo.get!(Session, session.id).activity_cursor == 1
      after
        stop_tasks([preflight, activity])
        cleanup(command)
      end
    end)
  end

  defp preflight_contender(claim, parent) do
    unboxed_task(fn -> database_result(fn -> preflight_after_owner_lock(claim, parent) end) end)
  end

  defp preflight_after_owner_lock(claim, parent) do
    Repo.transaction(fn ->
      Repo.one!(
        from(episode in Episode,
          where: episode.id == ^claim.episode.id,
          lock: "FOR UPDATE"
        )
      )

      send(parent, {:episode_locked, backend_pid()})

      receive do
        :preflight ->
          Custody.record_final_preflight(
            claim.episode.id,
            claim.turn.turn_ref,
            claim.lease_ref,
            String.duplicate("b", 64),
            String.duplicate("c", 64),
            claim.episode.semantic_version
          )
      end
    end)
  end

  defp activity_contender(session, parent) do
    unboxed_task(fn ->
      send(parent, {:activity_backend, backend_pid()})
      database_result(fn -> Activity.ingest(session.id, [activity_event(session)]) end)
    end)
  end

  defp database_result(fun) do
    fun.()
  rescue
    error in Postgrex.Error -> {:database_error, error.postgres.code}
  end

  defp activity_event(session) do
    %{
      "id" => "activity:#{session.id}:1",
      "session_id" => session.coop_session_id,
      "sequence" => 1,
      "type" => "tool.started",
      "version" => 1,
      "occurred_at" => DateTime.to_iso8601(@now),
      "payload" => %{"tool_call_id" => "activity-preflight"}
    }
  end

  defp create_episode! do
    suffix = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: Ecto.UUID.generate(),
        episode_key: "work-concurrency:#{suffix}",
        native_input_id: "source:#{suffix}",
        occurred_at: @now,
        turn_ref: "turn:#{suffix}"
      })

    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             Custody.pin_episode(command.episode_id, "work-read-only", String.duplicate("a", 64))

    command
  end

  defp cleanup(command) do
    Repo.delete_all(
      from(activity in ActivityEvent, where: activity.episode_id == ^command.episode_id)
    )

    Repo.delete_all(from(turn in Turn, where: turn.episode_id == ^command.episode_id))
    Repo.delete_all(from(session in Session, where: session.episode_id == ^command.episode_id))
    Repo.delete_all(from(event in Event, where: event.episode_id == ^command.episode_id))
    Repo.delete_all(from(episode in Episode, where: episode.id == ^command.episode_id))
  end
end
