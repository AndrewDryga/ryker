defmodule Ryker.Work.CustodyConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false
  import Ecto.Query
  import Ryker.TestHelpers, only: [digest: 1]
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Episodes
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Fixtures.WorkSessions
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Work.{Activity, ActivityEvent, Cancellation, Custody, OperationKeys, Session}
  alias Ryker.Work.{Submission, Turn}

  @now ~U[2026-08-28 12:00:00.000000Z]

  # A publication rejection can admit a new input while accepting a result.
  # Taking its conversation lock after the episode reversed ingress's order
  # and let concurrent feedback deadlock acceptance. Check the lock order
  # before validation, so the downstream missing-result error cannot hide it.
  test "result acceptance waits for the conversation before owning its episode" do
    Sandbox.unboxed_run(Repo, fn ->
      command = create_episode!()
      {:ok, claim} = Custody.claim_next("accept-order", 60, :work)
      parent = self()

      ingress =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            :ok = Episodes.ConversationLock.lock(command.destination)
            send(parent, {:conversation_locked, backend_pid()})

            receive do
              :inspect_episode ->
                {:ok, _} = Episodes.fetch_and_lock_current_in_transaction(command.episode_key)
                send(parent, :episode_accessible)
            end
          end)
        end)

      assert_receive {:conversation_locked, ingress_backend}, 5_000

      acceptance =
        unboxed_task(fn ->
          send(parent, {:acceptance_backend, backend_pid()})

          Custody.accept_result(
            command.episode_id,
            command.episode_key,
            claim.turn.turn_ref,
            claim.lease_ref,
            String.duplicate("a", 64),
            1,
            "validation:lock-order"
          )
        end)

      try do
        assert_receive {:acceptance_backend, acceptance_backend}, 5_000
        await_blocked_by(acceptance_backend, ingress_backend)
        send(ingress.pid, :inspect_episode)
        assert_receive :episode_accessible, 5_000
        assert Task.await(ingress, 5_000) == {:ok, :episode_accessible}
        assert {:error, _validation_not_prepared} = Task.await(acceptance, 5_000)
      after
        send(ingress.pid, :inspect_episode)
        stop_tasks([ingress, acceptance])
      end
    end)
  end

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

        # This runs on committed rows a serial partition shares with the tests
        # before it, so only claims of this episode count: a contender that
        # found nothing, or work some earlier test left claimable, is no
        # second owner of this turn.
        id = command.episode_id
        claims = for {:ok, %{turn: %{episode_id: ^id} = claimed}} <- results, do: claimed

        assert length(claims) == 1
        assert Repo.aggregate(from(turn in Turn, where: turn.episode_id == ^id), :count) == 1

        assert Repo.aggregate(from(session in Session, where: session.episode_id == ^id), :count) ==
                 1
      after
        stop_tasks(contenders)
      end
    end)
  end

  # A claim chooses its episode from the snapshot its query started with, and
  # a claim writes the turn, not the episode row the choice locks: a worker
  # whose choice predated another's committed claim locked the episode after
  # it and overwrote that worker's lease. Two pool workers owned one turn on a
  # loaded gate (2026-10-07).
  test "a worker never takes a turn another worker leased after it chose the episode" do
    Sandbox.unboxed_run(Repo, fn ->
      command = create_episode!()
      session = Repo.get_by!(Session, episode_id: command.episode_id)

      turn =
        Ecto.UUID.generate()
        |> Turn.Changeset.insert(command.episode_id, session.id, command.turn_ref)
        |> Repo.insert!()

      # First in line, ahead of anything an earlier test left claimable.
      Repo.update_all(from(episode in Episode, where: episode.id == ^command.episode_id),
        set: [updated_at: ~U[2000-01-01 00:00:00.000000Z]]
      )

      parent = self()

      # The first worker's claim, caught holding the session and its new lease
      # before it commits, as Custody's own claim holds them.
      first =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            Repo.one!(
              from(locked in Session, where: locked.id == ^session.id, lock: "FOR UPDATE")
            )

            Repo.update_all(from(leased in Turn, where: leased.id == ^turn.id),
              set: [
                lease_expires_at: DateTime.add(Repo.now!(), 60, :second),
                lease_owner: "worker:first",
                lease_ref: "work-lease:first"
              ]
            )

            send(parent, {:first_leased, backend_pid()})

            receive do
              :commit -> :ok
            end
          end)
        end)

      second =
        unboxed_task(fn ->
          receive do
            :claim -> :ok
          end

          send(parent, {:second_claiming, backend_pid()})
          Custody.claim_next("worker:second", 60, :work)
        end)

      try do
        assert_receive {:first_leased, first_backend}, 5_000
        send(second.pid, :claim)
        assert_receive {:second_claiming, second_backend}, 5_000
        await_blocked_by(second_backend, first_backend)
        send(first.pid, :commit)
        assert Task.await(first, 5_000) == {:ok, :ok}

        refute match?({:ok, %{turn: %{id: id}}} when id == turn.id, Task.await(second, 5_000))
        assert Repo.get!(Turn, turn.id).lease_ref == "work-lease:first"
      after
        send(first.pid, :commit)
        stop_tasks([first, second])
      end
    end)
  end

  test "activity ingestion cannot deadlock host validation holding its episode owner" do
    # September 9's concurrent-human-feedback World run returned HTTP 500 from
    # validate_final: activity held Session then waited on its Episode FK while
    # preflight held Episode then waited on Session. The model had to retry.
    # This one-event structural page reproduces those locks without a model call.
    Sandbox.unboxed_run(Repo, fn ->
      command = create_episode!()
      claim = staged_claim!(command)
      session = claim.session

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
      end
    end)
  end

  test "new workspace requirements cannot bypass completion checks while validation waits for its owner" do
    # The host can fetch workspace evidence before acquiring the owner lock.
    # A completed writable goal added in that gap must not be accepted with no
    # workspace check, even though there are no remaining open required goals.
    Sandbox.unboxed_run(Repo, fn ->
      command = create_episode!()
      claim = staged_claim!(command)
      parent = self()

      writer =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            {:ok, _} = Episodes.fetch_and_lock_current_in_transaction(claim.episode.key)
            send(parent, {:goal_owner, backend_pid()})

            receive do
              :write_goals ->
                token = Records.token(claim.turn)

                {:ok, _} =
                  Records.create(token, "late-goal", "goal", %{
                    "authority" => "repository_write",
                    "completion_contract" => "The requested implementation is committed.",
                    "id" => "implement-feature",
                    "kind" => "engineering",
                    "requested_outcome" => "Implement the requested feature",
                    "required" => true,
                    "stage" => "implementation",
                    "writable_repository" => "ryker"
                  })

                {:ok, _} =
                  Records.create(token, "late-goal-complete", "goal_state", %{
                    "detail" => "Implementation completed in the workspace.",
                    "goal_id" => "implement-feature",
                    "state" => "completed"
                  })
            end
          end)
        end)

      assert_receive {:goal_owner, writer_backend}, 5_000

      validation =
        unboxed_task(fn ->
          send(parent, {:validation_reader, backend_pid()})

          Ryker.Work.Executor.Validation.ensure_validation_intent(
            claim,
            claim.turn.candidate_sha256,
            claim.turn.candidate_attempt,
            [],
            %{
              validation_context: fn current ->
                Ryker.Work.ValidationContext.build(current.episode, current.turn)
              end
            }
          )
        end)

      try do
        assert_receive {:validation_reader, reader_backend}, 5_000
        await_blocked_by(reader_backend, writer_backend)
        send(writer.pid, :write_goals)
        assert {:ok, {:ok, _}} = Task.await(writer, 5_000)
        assert Task.await(validation, 5_000) == {:error, :work_validation_context_changed}
        assert Records.open_required_goals(claim.episode.id) == []
        turn = Repo.get!(Turn, claim.turn.id)
        assert turn.validation_intent == nil
        assert turn.validation_history == []
        assert turn.candidate_attempt == 1
      after
        send(writer.pid, :write_goals)
        stop_tasks([writer, validation])
      end
    end)
  end

  test "a state write waits for validation and cannot alter its accepted snapshot" do
    # Completion used to depend on a model preview. Moving it to the host must
    # serialize state writes and refuse a verdict whose facts changed afterward.
    Sandbox.unboxed_run(Repo, fn ->
      command = create_episode!()
      claim = staged_claim!(command)
      parent = self()

      validation =
        unboxed_task(fn ->
          Custody.prepare_candidate_validation(
            claim.episode.id,
            claim.turn.turn_ref,
            claim.lease_ref,
            claim.turn.candidate_sha256,
            claim.turn.candidate_attempt,
            fn current ->
              send(parent, {:validating, backend_pid()})

              receive do
                :finish_validation ->
                  assert Records.validation_records(claim.episode.id) == %{}
                  {:ok, result} = Ryker.Work.Result.new(:none, nil, "checked")

                  Custody.prepare_validation(
                    current.episode.id,
                    current.turn.turn_ref,
                    current.lease_ref,
                    current.turn.candidate_sha256,
                    current.turn.candidate_attempt,
                    :accept,
                    result
                  )
              end
            end
          )
        end)

      assert_receive {:validating, validation_backend}, 5_000

      writing =
        unboxed_task(fn ->
          send(parent, {:writing, backend_pid()})

          Records.create(Records.token(claim.turn), "late-question", "input_request", %{
            "question" => "Which revision?",
            "choices" => []
          })
        end)

      try do
        assert_receive {:writing, writing_backend}, 5_000
        await_blocked_by(writing_backend, validation_backend)
        send(validation.pid, :finish_validation)

        assert {:ok, %Turn{validation_intent: %{"verdict" => "accept"}}} =
                 Task.await(validation, 5_000)

        assert {:ok, _record} = Task.await(writing, 5_000)

        assert Custody.accept_result(
                 claim.episode.id,
                 claim.episode.key,
                 claim.turn.turn_ref,
                 claim.lease_ref,
                 claim.turn.candidate_sha256,
                 claim.turn.candidate_attempt,
                 "validation:concurrent-state"
               ) ==
                 {:error, :work_validation_state_changed}

        assert Repo.get!(Turn, claim.turn.id).result_ref == nil
      after
        send(validation.pid, :finish_validation)
        stop_tasks([validation, writing])
      end
    end)
  end

  defp staged_claim!(command) do
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

    {:ok, submission} =
      Submission.new(%{}, "Check current state.", %{"type" => "object"}, "work-final-live-v4")

    {:ok, _} =
      Custody.freeze_submission(
        command.episode_id,
        claim.turn.turn_ref,
        claim.lease_ref,
        submission
      )

    {:ok, turn} =
      Custody.bind_turn(
        command.episode_id,
        claim.turn.turn_ref,
        claim.lease_ref,
        session.generation,
        claim.turn.submit_generation,
        "remote-turn:#{command.episode_id}"
      )

    candidate = ~s({"delivery":"none","decision_reason":"checked"})

    {:ok, turn} =
      Custody.stage_candidate(
        command.episode_id,
        turn.turn_ref,
        claim.lease_ref,
        nil,
        nil,
        candidate,
        digest(candidate),
        1
      )

    claim = %{claim | turn: turn, session: session}

    claim
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

    clean_up_on_exit(fn -> cleanup(command) end)
    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             WorkSessions.pin_episode(id, "work-read-only", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:resume", 60)

    assert {:ok, submission} =
             Submission.new(
               %{"request" => "resume"},
               "Handle the request.",
               %{"type" => "object"},
               "work-final-live-v3"
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
               OperationKeys.cancel(work.turn.id, 1),
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
          Custody.prepare_candidate_validation(
            claim.episode.id,
            claim.turn.turn_ref,
            claim.lease_ref,
            claim.turn.candidate_sha256,
            claim.turn.candidate_attempt,
            fn current ->
              Custody.prepare_validation(
                current.episode.id,
                current.turn.turn_ref,
                current.lease_ref,
                current.turn.candidate_sha256,
                current.turn.candidate_attempt,
                {:reject, ["The probe needs more evidence."]},
                nil
              )
            end
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

    clean_up_on_exit(fn -> cleanup(command) end)
    assert {:ok, _transition} = Episodes.apply(command)

    assert {:ok, _session} =
             WorkSessions.pin_episode(
               command.episode_id,
               "work-read-only",
               String.duplicate("a", 64)
             )

    command
  end

  defp cleanup(command) do
    Repo.delete_all(
      from(activity in ActivityEvent, where: activity.episode_id == ^command.episode_id)
    )

    Repo.delete_all(
      from(record in Records.Record, where: record.episode_id == ^command.episode_id)
    )

    Repo.delete_all(from(turn in Turn, where: turn.episode_id == ^command.episode_id))
    Repo.delete_all(from(session in Session, where: session.episode_id == ^command.episode_id))
    Repo.delete_all(from(event in Event, where: event.episode_id == ^command.episode_id))
    Repo.delete_all(from(episode in Episode, where: episode.id == ^command.episode_id))
  end
end
