defmodule Responder.Slack.AdmissionConcurrencyTest do
  use Responder.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Responder.Episodes
  alias Responder.Episodes.{Command, Episode, Event}
  alias Responder.Repo
  alias Responder.Slack.{Admission, Inbox, Input}
  alias Responder.Slack.Admission.Decision
  alias Responder.Slack.Inbox.Entry

  @now ~U[2026-08-27 12:00:01.000000Z]

  test "simultaneous model decisions create one episode and one durable decision" do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      input = input!(suffix)
      assert {:ok, %{entry: entry}} = Inbox.record(input)
      assert {:ok, context} = context(entry)
      episode_key = "slack-input:#{entry.id}"

      assert {:ok, decision} =
               Decision.parse(%{
                 "action" => "start_episode",
                 "episode_ref" => nil,
                 "reaction" => nil,
                 "relation" => "unrelated",
                 "reason" => "This message asks Responder to do new work."
               })

      parent = self()
      blocker = entry_lock_task(entry.id, parent)
      assert_receive {:entry_locked, blocker_backend}, 5_000

      contenders =
        Enum.map(1..2, fn _index ->
          unboxed_task(fn ->
            send(parent, {:contender_ready, self(), backend_pid()})
            Admission.commit(context, decision, "decision:#{suffix}")
          end)
        end)

      contender_backends =
        Enum.map(contenders, fn contender ->
          contender_pid = contender.pid
          assert_receive {:contender_ready, ^contender_pid, backend}, 5_000
          backend
        end)

      try do
        Enum.each(contender_backends, fn contender_backend ->
          possible_blockers = [
            blocker_backend | List.delete(contender_backends, contender_backend)
          ]

          await_blocked_by_any(contender_backend, possible_blockers)
        end)

        send(blocker.pid, :release)

        results = Enum.map(contenders, &Task.await(&1, 5_000))

        assert Enum.sort(Enum.map(results, fn {:ok, result} -> result.status end)) == [
                 :applied,
                 :duplicate
               ]

        assert [stored] = Repo.all(from(inbox in Entry, where: inbox.id == ^entry.id))
        assert stored.status == :decided
        assert stored.decision_action == :start_episode

        assert [%{id: episode_id}] =
                 Repo.all(from(episode in Episode, where: episode.key == ^episode_key))

        assert Repo.aggregate(
                 from(event in Event, where: event.episode_id == ^episode_id),
                 :count
               ) ==
                 1
      after
        send(blocker.pid, :release)
        stop_tasks([blocker | contenders])
        Repo.delete_all(from(inbox in Entry, where: inbox.id == ^entry.id))

        case Repo.one(from(episode in Episode, where: episode.key == ^episode_key)) do
          nil -> :ok
          episode -> Repo.delete_all(from(event in Event, where: event.episode_id == ^episode.id))
        end

        Repo.delete_all(from(episode in Episode, where: episode.key == ^episode_key))
      end
    end)
  end

  test "context snapshots candidates and conversation generation under one creation lock" do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      input = input!(suffix)
      assert {:ok, %{entry: entry}} = Inbox.record(input)
      parent = self()
      blocker = conversation_lock_task(input, parent)
      assert_receive {:conversation_locked, blocker_backend}, 5_000

      context_task =
        unboxed_task(fn ->
          send(parent, {:context_ready, self(), backend_pid()})
          context(entry)
        end)

      context_pid = context_task.pid
      assert_receive {:context_ready, ^context_pid, context_backend}, 5_000

      episode_id = Ecto.UUID.generate()
      episode_key = "context-snapshot:#{episode_id}"

      try do
        await_blocked_by(context_backend, blocker_backend)

        assert {:ok, _transition} =
                 Episodes.apply(%Command.AdmitInput{
                   actor_ref: Input.actor_ref(input),
                   destination: Input.destination(input),
                   episode_id: episode_id,
                   episode_key: episode_key,
                   linked_episode_id: nil,
                   native_input_id: "snapshot-source:#{episode_id}",
                   occurred_at: DateTime.add(@now, -1, :second),
                   payload: Input.document(input),
                   revision: 1,
                   turn_ref: "snapshot-turn:#{episode_id}"
                 })

        send(blocker.pid, :release)
        assert {:ok, context} = Task.await(context_task, 5_000)
        assert context.conversation_episode_count == 1
        assert Enum.any?(context.candidates, &(&1.episode.id == episode_id))
      after
        send(blocker.pid, :release)
        stop_tasks([blocker, context_task])
        Repo.delete_all(from(inbox in Entry, where: inbox.id == ^entry.id))
        Repo.delete_all(from(event in Event, where: event.episode_id == ^episode_id))
        Repo.delete_all(from(episode in Episode, where: episode.id == ^episode_id))
      end
    end)
  end

  defp entry_lock_task(entry_id, parent) do
    unboxed_task(fn ->
      Repo.transaction(fn ->
        Repo.one!(from(entry in Entry, where: entry.id == ^entry_id, lock: "FOR UPDATE"))
        send(parent, {:entry_locked, backend_pid()})

        receive do
          :release -> :ok
        end
      end)
    end)
  end

  defp conversation_lock_task(input, parent) do
    conversation_ref = Input.destination(input).conversation_ref

    unboxed_task(fn ->
      Repo.transaction(fn ->
        Repo.query!(
          "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
          ["slack-admission:#{conversation_ref}"]
        )

        send(parent, {:conversation_locked, backend_pid()})

        receive do
          :release -> :ok
        end
      end)
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
        flunk("backend #{blocked_backend} never reached the serialized decision lock")

      true ->
        await_blocked_by_any(blocked_backend, possible_blockers, deadline)
    end
  end

  defp context(entry) do
    Admission.context(Inbox.ref(entry),
      now: @now,
      continuation_window: 1_800,
      history_window: 2_592_000,
      candidate_limit: 8
    )
  end

  defp input!(suffix) do
    assert {:ok, input} =
             Input.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C456",
               content: %{"text" => "Please handle this once."},
               event_kind: :message,
               event_ref: "Ev-#{suffix}",
               message_ref: "1787832000.#{String.slice(suffix, 0, 6)}",
               occurred_at: ~U[2026-08-27 12:00:00.000000Z],
               revision: 1,
               thread_ref: nil,
               workspace_ref: "T123"
             })

    input
  end
end
