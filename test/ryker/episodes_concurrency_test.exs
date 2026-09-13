defmodule Ryker.EpisodesConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Episodes
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Repo

  test "two first writers serialize into one accepted source event" do
    # Duplicate provider callbacks and Slack retries can arrive together. Both
    # writers must converge on one event even when neither observed an episode.
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()

      command =
        EpisodeFixtures.admit_input(%{
          episode_id: Ecto.UUID.generate(),
          episode_key: "concurrency:#{suffix}",
          native_input_id: "source:#{suffix}"
        })

      parent = self()
      blocker = source_lock_task(command.episode_key, parent)
      assert_receive {:source_locked, blocker_backend}, 5_000

      contenders = Enum.map(1..2, fn _index -> apply_task(command, parent) end)

      contender_backends =
        Enum.map(contenders, fn contender ->
          contender_pid = contender.pid
          assert_receive {:contender_ready, ^contender_pid, backend}, 5_000
          backend
        end)

      try do
        assert_admit_input_lock_chain(contender_backends, blocker_backend)
        send(blocker.pid, :release)

        results = Enum.map(contenders, &Task.await(&1, 5_000))

        assert Enum.sort(Enum.map(results, fn {:ok, transition} -> transition.status end)) == [
                 :applied,
                 :duplicate
               ]

        assert [%{sequence: 1}] = Episodes.list_events(command.episode_key)
      after
        send(blocker.pid, :release)
        stop_tasks([blocker | contenders])
        Repo.delete_all(from(event in Event, where: event.episode_id == ^command.episode_id))
        Repo.delete_all(from(episode in Episode, where: episode.id == ^command.episode_id))
      end
    end)
  end

  test "two distinct first inputs converge on the episode id allocated under the source lock" do
    # Different lifecycle revisions can race before either caller sees an
    # episode. The source key owns identity; a losing creation candidate must
    # join the stored episode rather than drop its accepted input.
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      episode_key = "first-input-race:#{suffix}"

      commands =
        Enum.map(["a", "b"], fn contender ->
          EpisodeFixtures.admit_input(%{
            episode_id: Ecto.UUID.generate(),
            episode_key: episode_key,
            native_input_id: "source:#{suffix}:#{contender}",
            occurred_at: ~U[2026-08-27 12:00:00.000000Z],
            payload: %{"contender" => contender},
            turn_ref: "turn-#{contender}"
          })
        end)

      parent = self()
      blocker = source_lock_task(episode_key, parent)
      assert_receive {:source_locked, blocker_backend}, 5_000
      contenders = Enum.map(commands, &apply_task(&1, parent))

      contender_backends =
        Enum.map(contenders, fn contender ->
          contender_pid = contender.pid
          assert_receive {:contender_ready, ^contender_pid, backend}, 5_000
          backend
        end)

      try do
        assert_admit_input_lock_chain(contender_backends, blocker_backend)
        send(blocker.pid, :release)

        assert Enum.all?(Enum.map(contenders, &Task.await(&1, 5_000)), fn
                 {:ok, %{status: :applied}} -> true
                 _result -> false
               end)

        assert {:ok, stored} = Episodes.fetch_by_key(episode_key)
        assert stored.id in Enum.map(commands, & &1.episode_id)
        assert Enum.map(Episodes.list_events(episode_key), & &1.sequence) == [1, 2]
      after
        send(blocker.pid, :release)
        stop_tasks([blocker | contenders])

        case Episodes.fetch_by_key(episode_key) do
          {:ok, stored} ->
            Repo.delete_all(from(event in Event, where: event.episode_id == ^stored.id))
            Repo.delete_all(from(episode in Episode, where: episode.id == ^stored.id))

          :error ->
            :ok
        end
      end
    end)
  end

  test "two owner contenders produce one fenced winner" do
    # Two replacement workers can become ready together after a restart. Only
    # one may acquire custody; the loser must see the winner, not append a
    # second transfer or overwrite the projection.
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()

      input =
        EpisodeFixtures.admit_input(%{
          episode_id: Ecto.UUID.generate(),
          episode_key: "owner-race:#{suffix}",
          native_input_id: "source:#{suffix}"
        })

      assert {:ok, _transition} = Episodes.apply(input)

      commands = [
        EpisodeFixtures.transfer_owner(%{
          episode_key: input.episode_key,
          new_owner: %{kind: :turn, ref: "turn-contender-a"},
          transfer_ref: "transfer-a"
        }),
        EpisodeFixtures.transfer_owner(%{
          episode_key: input.episode_key,
          new_owner: %{kind: :turn, ref: "turn-contender-b"},
          transfer_ref: "transfer-b"
        })
      ]

      parent = self()
      blocker = source_lock_task(input.episode_key, parent)
      assert_receive {:source_locked, blocker_backend}, 5_000
      contenders = Enum.map(commands, &apply_task(&1, parent))

      contender_backends =
        Enum.map(contenders, fn contender ->
          contender_pid = contender.pid
          assert_receive {:contender_ready, ^contender_pid, backend}, 5_000
          backend
        end)

      try do
        Enum.each(contender_backends, &await_blocked_by(&1, blocker_backend))
        send(blocker.pid, :release)
        results = Enum.map(contenders, &Task.await(&1, 5_000))

        assert 1 == Enum.count(results, &match?({:ok, %{status: :applied}}, &1))
        assert 1 == Enum.count(results, &match?({:error, {:stale_owner, _}}, &1))

        assert {:ok, stored} = Episodes.fetch_by_key(input.episode_key)
        assert stored.owner_ref in ["turn-contender-a", "turn-contender-b"]

        assert Enum.count(
                 Episodes.list_events(input.episode_key),
                 &(&1.kind == :owner_transferred)
               ) == 1
      after
        send(blocker.pid, :release)
        stop_tasks([blocker | contenders])
        Repo.delete_all(from(event in Event, where: event.episode_id == ^input.episode_id))
        Repo.delete_all(from(episode in Episode, where: episode.id == ^input.episode_id))
      end
    end)
  end

  defp source_lock_task(episode_key, parent) do
    unboxed_task(fn ->
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [episode_key])
        send(parent, {:source_locked, backend_pid()})

        receive do
          :release -> :ok
        end
      end)
    end)
  end

  defp apply_task(command, parent) do
    unboxed_task(fn ->
      send(parent, {:contender_ready, self(), backend_pid()})
      Episodes.apply(command)
    end)
  end

  defp assert_admit_input_lock_chain(contender_backends, source_blocker) do
    Enum.each(contender_backends, fn contender_backend ->
      possible_blockers = [source_blocker | List.delete(contender_backends, contender_backend)]
      await_blocked_by_any(contender_backend, possible_blockers)
    end)
  end

  defp await_blocked_by_any(blocked_backend, possible_blockers, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    %{rows: [[blocking_backends]]} =
      Repo.query!("SELECT pg_blocking_pids($1::integer)", [blocked_backend])

    cond do
      Enum.any?(blocking_backends, &(&1 in possible_blockers)) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("backend #{blocked_backend} never reached the serialized input lock chain")

      true ->
        await_blocked_by_any(blocked_backend, possible_blockers, deadline)
    end
  end
end
