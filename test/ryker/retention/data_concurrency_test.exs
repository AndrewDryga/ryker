defmodule Ryker.Retention.DataConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Artifacts
  alias Ryker.Episodes
  alias Ryker.Episodes.{Episode, Event}
  alias Ryker.Fixtures.Episodes, as: EpisodeFixtures
  alias Ryker.Ingress.{Inbox, Input}
  alias Ryker.Repo
  alias Ryker.Retention.Data

  @old ~U[2020-01-01 00:00:00.000000Z]

  test "artifact deletion cannot race ahead of durable input custody" do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()

      assert {:ok, artifact} =
               Artifacts.put(%{
                 data: "artifact body #{suffix}",
                 media_type: "text/plain",
                 name: "evidence.txt",
                 source_kind: "slack",
                 source_ref: "T-retention:F-#{suffix}"
               })

      input = artifact_input!(artifact, suffix)
      parent = self()

      try do
        blocker =
          unboxed_task(fn ->
            Repo.transaction(fn ->
              Repo.query!("SELECT id FROM input_artifacts WHERE id = $1 FOR UPDATE", [
                Ecto.UUID.dump!(artifact.id)
              ])

              send(parent, {:artifact_locked, backend_pid()})

              receive do
                :delete_artifact ->
                  Repo.query!("DELETE FROM input_artifacts WHERE id = $1", [
                    Ecto.UUID.dump!(artifact.id)
                  ])
              end
            end)
          end)

        Process.put({__MODULE__, :artifact_blocker}, blocker)
        assert_receive {:artifact_locked, blocker_backend}, 5_000

        recorder =
          unboxed_task(fn ->
            backend = backend_pid()
            send(parent, {:artifact_recorder_started, self(), backend})
            result = Inbox.record(input)
            send(parent, {:artifact_recorder_finished, self(), result})
            result
          end)

        Process.put({__MODULE__, :artifact_recorder}, recorder)
        recorder_pid = recorder.pid
        assert_receive {:artifact_recorder_started, ^recorder_pid, recorder_backend}, 5_000

        recorder_state =
          await_artifact_finished_or_blocked(recorder, recorder_backend, blocker_backend)

        send(blocker.pid, :delete_artifact)
        assert {:ok, _transaction} = Task.await(blocker, 5_000)

        result =
          case recorder_state do
            {:finished, result} -> result
            :blocked -> Task.await(recorder, 5_000)
          end

        assert {:error, :input_artifact_not_found} = result
        assert Repo.aggregate(Ryker.Ingress.Inbox.Entry, :count) == 0
      after
        tasks =
          [
            Process.delete({__MODULE__, :artifact_blocker}),
            Process.delete({__MODULE__, :artifact_recorder})
          ]
          |> Enum.reject(&is_nil/1)

        Enum.each(tasks, &send(&1.pid, :delete_artifact))
        stop_tasks(tasks)
        Repo.delete_all(Ryker.Ingress.Inbox.Entry)
        Repo.delete_all(Ryker.Artifacts.Artifact)
      end
    end)
  end

  test "history pruning cannot overtake an episode reopened by another transaction" do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      episode = completed_episode!(suffix)
      parent = self()

      try do
        blocker =
          unboxed_task(fn ->
            Repo.transaction(fn ->
              Repo.one!(from(row in Episode, where: row.id == ^episode.id, lock: "FOR UPDATE"))
              send(parent, {:episode_locked, backend_pid()})

              receive do
                {:reopen, command} ->
                  result = Episodes.apply(command)
                  send(parent, {:episode_reopened, result})
              end
            end)
          end)

        Process.put({__MODULE__, :blocker}, blocker)
        assert_receive {:episode_locked, blocker_backend}, 5_000

        pruner =
          unboxed_task(fn ->
            backend = backend_pid()
            send(parent, {:pruner_started, self(), backend})
            result = Data.prune(settings())
            send(parent, {:pruner_finished, self(), result})
            result
          end)

        Process.put({__MODULE__, :pruner}, pruner)
        pruner_pid = pruner.pid
        assert_receive {:pruner_started, ^pruner_pid, pruner_backend}, 5_000
        prune_state = await_finished_or_blocked(pruner, pruner_backend, blocker_backend)

        reopen =
          EpisodeFixtures.admit_input(%{
            actor_ref: "slack:user:U2",
            destination: destination(),
            episode_id: episode.id,
            episode_key: episode.key,
            native_input_id: "retention-reopen:#{suffix}",
            occurred_at: ~U[2026-08-29 12:00:00.000000Z],
            payload: %{"text" => "New work arrived while retention was selecting history."},
            revision: 1,
            turn_ref: "turn:retention-reopen:#{suffix}"
          })

        send(blocker.pid, {:reopen, reopen})
        assert_receive {:episode_reopened, {:ok, _transition}}, 5_000
        assert {:ok, _transaction} = Task.await(blocker, 5_000)

        prune_result =
          case prune_state do
            {:finished, result} -> result
            :blocked -> Task.await(pruner, 5_000)
          end

        assert {:ok, %{episode_histories: 0}} = prune_result

        stored = Repo.get!(Episode, episode.id)
        assert stored.state == :working
        assert stored.history_pruned_at == nil

        assert Repo.aggregate(
                 from(event in Event, where: event.episode_id == ^episode.id),
                 :count
               ) ==
                 3
      after
        tasks =
          [Process.delete({__MODULE__, :blocker}), Process.delete({__MODULE__, :pruner})]
          |> Enum.reject(&is_nil/1)

        Enum.each(tasks, fn task -> send(task.pid, {:reopen, nil}) end)
        stop_tasks(tasks)
        Repo.delete_all(from(event in Event, where: event.episode_id == ^episode.id))
        Repo.delete_all(from(row in Episode, where: row.id == ^episode.id))
      end
    end)
  end

  defp completed_episode!(suffix) do
    id = Ecto.UUID.generate()
    key = "retention-race:#{suffix}"
    turn_ref = "turn:retention-race:#{suffix}"

    assert {:ok, _transition} =
             Episodes.apply(
               EpisodeFixtures.admit_input(%{
                 destination: destination(),
                 episode_id: id,
                 episode_key: key,
                 native_input_id: "retention-original:#{suffix}",
                 payload: %{"text" => "Original completed work."},
                 turn_ref: turn_ref
               })
             )

    assert {:ok, transition} =
             Episodes.apply(
               EpisodeFixtures.accept_result(%{
                 decision_reason: "No visible delivery is required.",
                 delivery: :none,
                 delivery_ref: nil,
                 episode_key: key,
                 expected_turn_ref: turn_ref,
                 result_ref: "result:retention-race:#{suffix}"
               })
             )

    Repo.query!("UPDATE episode_kernel_episodes SET updated_at = $1 WHERE id = $2", [
      @old,
      Ecto.UUID.dump!(id)
    ])

    transition.episode
  end

  defp artifact_input!(artifact, suffix) do
    assert {:ok, input} =
             Input.new(%{
               actor: %{kind: :user, ref: "U-retention"},
               content: %{
                 "files" => [
                   %{
                     "artifact_ref" => artifact.ref,
                     "bytes" => artifact.byte_size,
                     "media_type" => artifact.media_type,
                     "name" => artifact.name,
                     "sha256" => artifact.sha256,
                     "status" => "available"
                   }
                 ],
                 "text" => "Use the attached evidence."
               },
               destination: %{
                 conversation_ref: "slack:T-retention:C-retention",
                 thread_ref: "1788000000.000001",
                 transport: "slack"
               },
               event_kind: :message,
               event_ref: "retention-artifact:#{suffix}",
               native_input_id: "retention-artifact:#{suffix}",
               occurred_at: ~U[2026-08-29 12:00:00.000000Z],
               occurred_at_source: :source,
               revision: 1,
               source: %{kind: "slack", ref: "T-retention"},
               source_capabilities: %{"react" => %{"emoji_names" => nil}},
               source_item_ref: "1788000000.000001"
             })

    input
  end

  defp await_finished_or_blocked(task, backend, blocker, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    receive do
      {:pruner_finished, pid, result} when pid == task.pid ->
        {:finished, result}
    after
      0 ->
        %{rows: [[blocking_backends]]} =
          Repo.query!("SELECT pg_blocking_pids($1::integer)", [backend])

        cond do
          blocker in blocking_backends ->
            :blocked

          System.monotonic_time(:millisecond) > deadline ->
            flunk("retention neither skipped nor serialized on the locked episode")

          true ->
            receive do
            after
              10 -> await_finished_or_blocked(task, backend, blocker, deadline)
            end
        end
    end
  end

  defp await_artifact_finished_or_blocked(task, backend, blocker, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 5_000

    receive do
      {:artifact_recorder_finished, pid, result} when pid == task.pid ->
        {:finished, result}
    after
      0 ->
        %{rows: [[blocking_backends]]} =
          Repo.query!("SELECT pg_blocking_pids($1::integer)", [backend])

        cond do
          blocker in blocking_backends ->
            :blocked

          System.monotonic_time(:millisecond) > deadline ->
            flunk("input custody neither finished nor serialized on the artifact")

          true ->
            receive do
            after
              10 ->
                await_artifact_finished_or_blocked(task, backend, blocker, deadline)
            end
        end
    end
  end

  defp destination do
    %{
      conversation_ref: "slack:T1:C-retention",
      thread_ref: "1788000000.000001",
      transport: "slack"
    }
  end

  defp settings do
    %{
      audit_data_seconds: 60,
      closed_work_seconds: 60,
      conversation_memory_seconds: 60,
      episode_history_seconds: 60,
      operational_data_seconds: 60
    }
  end
end
