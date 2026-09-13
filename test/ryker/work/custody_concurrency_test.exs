defmodule Ryker.Work.CustodyConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Episodes
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Repo
  alias Ryker.Work.{Activity, ActivityEvent, Cancellation, Custody, Session, Submission, Turn}

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

  test "two operators resuming one blocked task start exactly one replacement" do
    # `blocked-task-recovery.md`: duplicate click and concurrent resume must
    # yield one path. Sequentially the recovery fingerprint refuses the second
    # press, but two operators reading the same card press against the same
    # fingerprint — nothing there is stale until one of them commits.
    Sandbox.unboxed_run(Repo, fn ->
      occupied = non_empty_tables()
      work = blocked_work!()
      fingerprint = Custody.recovery_fingerprint(work.turn)
      parent = self()

      contenders =
        Enum.map(1..2, fn _index ->
          unboxed_task(fn ->
            send(parent, {:ready, self()})

            receive do
              :resume -> Custody.retry_blocked(work.episode.key, fingerprint)
            end
          end)
        end)

      try do
        Enum.each(contenders, fn contender ->
          contender_pid = contender.pid
          assert_receive {:ready, ^contender_pid}, 5_000
        end)

        Enum.each(contenders, &send(&1.pid, :resume))
        results = Enum.map(contenders, &Task.await(&1, 5_000))

        # One resume starts; the other is refused under the same episode lock.
        # Which refusal it reads depends on whether the replacement has been
        # claimed yet — `work_recovery_changed` once its turn exists, and
        # `work_turn_not_found` in this window, where the episode already names
        # an owner no worker has claimed. Both refuse, which is the invariant.
        assert Enum.count(results, &match?({:ok, _episode}, &1)) == 1

        assert Enum.count(
                 results,
                 &(&1 in [{:error, :work_recovery_changed}, {:error, :work_turn_not_found}])
               ) == 1

        # The episode owns exactly one replacement, and no second one was
        # created behind it.
        episode = Repo.get!(Episode, work.episode.id)
        assert episode.owner_ref =~ "turn:resume-blocked:#{work.turn.id}:v"

        assert Repo.aggregate(
                 from(turn in Turn, where: turn.episode_id == ^work.episode.id),
                 :count
               ) == 1

        assert {:ok, claimed} = Custody.claim_next("worker:resume-replacement", 60, :work)
        assert claimed.turn.turn_ref == episode.owner_ref
        assert claimed.session.generation == work.session.generation + 1
      after
        stop_tasks(contenders)
        cleanup(%{episode_id: work.episode.id})
      end

      # This test commits for real, so it owns its cleanup. Stated as the
      # invariant rather than a list of tables to remember: one orphaned
      # accounting row from a sibling test turned the whole gate red on
      # 18376794, because the world runner refuses a database that is not empty.
      leaked = non_empty_tables() -- occupied

      assert leaked == [],
             "unboxed work must leave the database as it found it, " <>
               "but #{inspect(leaked)} still holds rows"
    end)
  end

  defp non_empty_tables do
    %{rows: rows} =
      Repo.query!("""
      SELECT table_name
      FROM information_schema.tables
      WHERE table_schema = current_schema()
        AND table_type = 'BASE TABLE'
        AND table_name <> 'schema_migrations'
      ORDER BY table_name
      """)

    rows
    |> Enum.map(fn [table] -> table end)
    |> Enum.reject(fn table ->
      quoted = ~s("#{String.replace(table, "\"", "\"\"")}")
      %{rows: [[empty]]} = Repo.query!("SELECT NOT EXISTS (SELECT 1 FROM #{quoted} LIMIT 1)")
      empty
    end)
  end

  defp blocked_work! do
    id = Ecto.UUID.generate()

    command =
      EpisodeFixtures.admit_input(%{
        episode_id: id,
        episode_key: "work-resume:#{id}",
        native_input_id: "source:resume:#{id}",
        occurred_at: @now,
        turn_ref: "turn:resume:#{id}"
      })

    assert {:ok, _transition} = Episodes.apply(command)
    assert {:ok, _session} = Custody.pin_episode(id, "work-read-only", String.duplicate("a", 64))
    assert {:ok, claim} = Custody.claim_next("worker:resume", 60)

    assert {:ok, submission} =
             Submission.new(
               %{"request" => "resume"},
               "Handle the request.",
               %{"type" => "object"},
               "work-final-v1"
             )

    assert {:ok, _turn} =
             Custody.freeze_submission(id, command.turn_ref, claim.lease_ref, submission)

    assert {:ok, session} =
             Custody.bind_session(
               id,
               command.turn_ref,
               claim.lease_ref,
               claim.session.generation,
               claim.session.create_generation,
               "coop-session:#{id}"
             )

    assert {:ok, turn} =
             Custody.bind_turn(
               id,
               command.turn_ref,
               claim.lease_ref,
               session.generation,
               claim.turn.submit_generation,
               "coop-turn:#{id}"
             )

    work = %{episode: claim.episode, lease_ref: claim.lease_ref, session: session, turn: turn}

    assert {:ok, _requested} =
             Custody.request_block(
               id,
               claim.episode.key,
               command.turn_ref,
               claim.lease_ref,
               "The executor needs operator recovery."
             )

    assert {:ok, stop_claim} = Custody.claim_next("worker:resume-stop", 60, :work)

    assert {:ok, blocked} =
             Custody.settle_cancellation(
               id,
               claim.episode.key,
               command.turn_ref,
               stop_claim.lease_ref,
               terminal_receipt!(work)
             )

    assert blocked.turn.status == :blocked
    %{work | turn: blocked.turn}
  end

  defp terminal_receipt!(work) do
    assert {:ok, receipt} =
             Cancellation.terminal_receipt(
               work.session.coop_session_id,
               work.turn.coop_turn_id,
               "cancelled",
               Cancellation.operation_key(work.turn.id, 1),
               "closed",
               "ryker:work:cancel-close:#{work.turn.id}:g1"
             )

    receipt
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
