defmodule Responder.State.EventWaitConcurrencyTest do
  use Responder.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Responder.Episodes
  alias Responder.Episodes.{Episode, Event}
  alias Responder.Fixtures.Episodes, as: EpisodeFixtures
  alias Responder.Repo
  alias Responder.State.{EventSubscription, EventSubscriptions, EventWaits, Record, Records}
  alias Responder.Work.{Custody, Session, Turn}

  test "two timer workers create exactly one continuation under actual database contention" do
    # A resumed observation must not fork into two model turns when workers or
    # restart reconciliation overlap on the same retained wait.
    Sandbox.unboxed_run(Repo, fn ->
      episode_id = Ecto.UUID.generate()
      episode_key = "timer-race:#{episode_id}"

      try do
        {record, subscription} = timer_fixture!(episode_id, episode_key)
        parent = self()

        blocker =
          unboxed_task(fn ->
            Repo.transaction(fn ->
              Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [episode_key])
              send(parent, {:timer_locked, backend_pid()})

              receive do
                :release -> :ok
              end
            end)
          end)

        assert_receive {:timer_locked, blocking_backend}, 5_000

        contenders =
          for _index <- 1..2 do
            unboxed_task(fn ->
              send(parent, {:timer_ready, self(), backend_pid()})
              EventWaits.resume_at(record.id, episode_id, subscription.poll_after)
            end)
          end

        try do
          Enum.each(contenders, fn contender ->
            pid = contender.pid
            assert_receive {:timer_ready, ^pid, backend}, 5_000
            await_blocked_by(backend, blocking_backend)
          end)

          send(blocker.pid, :release)
          results = Enum.map(contenders, &Task.await(&1, 5_000))
          assert Enum.count(results, &match?({:ok, %{record: %{status: :answered}}}, &1)) == 1
          assert Enum.count(results, &(&1 == {:ok, :idle})) == 1
          assert {:ok, :ok} = Task.await(blocker, 5_000)

          events = Episodes.list_events(episode_key)
          assert Enum.count(events, &(&1.kind == :wait_resumed)) == 1
          assert Enum.count(events, &(&1.kind == :input_admitted)) == 2
          assert Repo.get!(EventSubscription, subscription.id).revision == 2
        after
          send(blocker.pid, :release)
          stop_tasks([blocker | contenders])
        end
      after
        Repo.delete_all(from(row in EventSubscription, where: row.episode_id == ^episode_id))
        Repo.delete_all(from(row in Record, where: row.episode_id == ^episode_id))
        Repo.delete_all(from(row in Turn, where: row.episode_id == ^episode_id))
        Repo.delete_all(from(row in Session, where: row.episode_id == ^episode_id))
        Repo.delete_all(from(row in Event, where: row.episode_id == ^episode_id))
        Repo.delete_all(from(row in Episode, where: row.id == ^episode_id))
      end
    end)
  end

  defp timer_fixture!(episode_id, episode_key) do
    %{rows: [[now]]} = Repo.query!("SELECT clock_timestamp()")
    deadline = DateTime.add(now, 900, :second)
    turn_ref = "turn:#{episode_key}"

    assert {:ok, _admitted} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 episode_id: episode_id,
                 episode_key: episode_key,
                 native_input_id: "input:#{episode_key}",
                 occurred_at: now,
                 turn_ref: turn_ref
               })
             )

    assert {:ok, _session} =
             Custody.pin_episode(episode_id, "responder-read", String.duplicate("a", 64))

    assert {:ok, claim} = Custody.claim_next("worker:#{episode_key}", 60, :work)

    assert {:ok, record} =
             Records.create(Records.token(claim.turn), "timer", "event_wait", %{
               "deadline_at" => DateTime.to_iso8601(deadline),
               "event_matcher" => %{
                 "type" => "after",
                 "delay" => "10m",
                 "on_timeout" => "Report the verification gap."
               },
               "kind" => "after",
               "verification" => "Verify the deployment after observation."
             })

    assert {:ok, waiting} =
             Episodes.apply(
               EpisodeFixtures.start_wait(%{
                 deadline_at: deadline,
                 episode_key: episode_key,
                 expected_turn_ref: turn_ref,
                 kind: :event,
                 occurred_at: now,
                 wait_ref: record.ref
               })
             )

    assert {:ok, {:ok, subscription}} =
             Repo.transaction(fn -> EventSubscriptions.ensure_in_transaction(waiting.episode) end)

    {record, subscription}
  end
end
