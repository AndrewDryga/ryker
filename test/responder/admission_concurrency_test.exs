defmodule Responder.AdmissionConcurrencyTest do
  use Responder.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Responder.Admission
  alias Responder.Admission.Decision
  alias Responder.Episodes
  alias Responder.Episodes.{Command, Episode, Event}
  alias Responder.Ingress.{Inbox, Input}
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Repo
  alias Responder.Slack.Input, as: SlackInput

  @now ~U[2026-08-27 12:00:01.000000Z]

  test "simultaneous model decisions create one episode and one durable decision" do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      input = input!(suffix)
      assert {:ok, %{entry: entry}} = Inbox.record(input)
      assert {:ok, context} = context(entry)
      episode_key = "ingress-input:#{entry.id}"

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

  test "context and concurrent input admission observe one coherent ordering" do
    # A source update can land while classification waits for the conversation
    # lock. Mixing before/after reads could make a stale context look current
    # and split one conversation into two episodes.
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

      creator =
        unboxed_task(fn ->
          send(parent, {:creator_ready, self(), backend_pid()})

          Episodes.apply(%Command.AdmitInput{
            actor_ref: Input.actor_ref(input),
            destination: input.destination,
            episode_id: episode_id,
            episode_key: episode_key,
            linked_episode_id: nil,
            native_input_id: "snapshot-source:#{episode_id}",
            occurred_at: DateTime.add(@now, -1, :second),
            payload: Input.document(input),
            revision: 1,
            turn_ref: "snapshot-turn:#{episode_id}"
          })
        end)

      creator_pid = creator.pid
      assert_receive {:creator_ready, ^creator_pid, creator_backend}, 5_000

      try do
        await_blocked_by(context_backend, blocker_backend)
        await_blocked_by(creator_backend, blocker_backend)

        send(blocker.pid, :release)
        assert {:ok, context} = Task.await(context_task, 5_000)
        assert {:ok, _transition} = Task.await(creator, 5_000)

        candidate_ids = Enum.map(context.candidates, & &1.episode.id)
        assert context.conversation_episode_count in [0, 1]
        assert length(candidate_ids) == context.conversation_episode_count

        if context.conversation_episode_count == 0 do
          assert {:ok, decision} =
                   Decision.parse(%{
                     "action" => "start_episode",
                     "episode_ref" => nil,
                     "reaction" => nil,
                     "relation" => "unrelated",
                     "reason" => "The frozen snapshot offered no existing work."
                   })

          assert {:error, {:admission_rejected, :context_stale}} =
                   Admission.commit(context, decision, "decision:#{suffix}")
        else
          assert candidate_ids == [episode_id]
        end
      after
        send(blocker.pid, :release)
        stop_tasks([blocker, context_task, creator])
        Repo.delete_all(from(inbox in Entry, where: inbox.id == ^entry.id))
        Repo.delete_all(from(event in Event, where: event.episode_id == ^episode_id))
        Repo.delete_all(from(episode in Episode, where: episode.id == ^episode_id))
      end
    end)
  end

  test "every admitted input waits for the conversation routing lock" do
    # An input admitted outside the model-admission path can reopen work while
    # a routing decision is committing. Both paths must use the same short
    # conversation lock or one lifecycle can split into two episodes.
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      input = input!(suffix)
      episode_id = Ecto.UUID.generate()
      episode_key = "conversation-lock:#{episode_id}"
      parent = self()
      blocker = conversation_lock_task(input, parent)
      assert_receive {:conversation_locked, blocker_backend}, 5_000

      admitted =
        unboxed_task(fn ->
          send(parent, {:admit_started, self(), backend_pid()})

          Episodes.apply(%Command.AdmitInput{
            actor_ref: Input.actor_ref(input),
            destination: input.destination,
            episode_id: episode_id,
            episode_key: episode_key,
            linked_episode_id: nil,
            native_input_id: input.native_input_id,
            occurred_at: input.occurred_at,
            payload: Input.document(input),
            revision: input.revision,
            turn_ref: "turn-conversation-lock:#{episode_id}"
          })
        end)

      admitted_pid = admitted.pid
      assert_receive {:admit_started, ^admitted_pid, admitted_backend}, 5_000

      try do
        await_blocked_by(admitted_backend, blocker_backend)
        send(blocker.pid, :release)
        assert {:ok, _transition} = Task.await(admitted, 5_000)
      after
        send(blocker.pid, :release)
        stop_tasks([blocker, admitted])
        Repo.delete_all(from(event in Event, where: event.episode_id == ^episode_id))
        Repo.delete_all(from(episode in Episode, where: episode.id == ^episode_id))
      end
    end)
  end

  test "a concurrent episode reopen is serialized before new work can be created" do
    Sandbox.unboxed_run(Repo, fn ->
      suffix = Ecto.UUID.generate()
      input = input!(suffix)
      old_id = Ecto.UUID.generate()
      old_key = "reopen-serialization:#{old_id}"
      old_turn = "turn-old:#{old_id}"

      assert {:ok, _admitted} =
               Episodes.apply(%Command.AdmitInput{
                 actor_ref: Input.actor_ref(input),
                 destination: input.destination,
                 episode_id: old_id,
                 episode_key: old_key,
                 linked_episode_id: nil,
                 native_input_id: "old-source:#{old_id}",
                 occurred_at: DateTime.add(@now, -120, :second),
                 payload: Input.document(input),
                 revision: 1,
                 turn_ref: old_turn
               })

      assert {:ok, _completed} =
               Episodes.apply(%Command.AcceptResult{
                 decision_reason: "The earlier work completed.",
                 delivery: :none,
                 delivery_ref: nil,
                 episode_key: old_key,
                 expected_turn_ref: old_turn,
                 next_turn_ref: nil,
                 occurred_at: DateTime.add(@now, -119, :second),
                 result_ref: "result-old:#{old_id}"
               })

      assert {:ok, %{entry: entry}} = Inbox.record(input)
      assert {:ok, context} = context(entry)
      candidate = Enum.find(context.candidates, &(&1.episode.id == old_id))

      assert {:ok, decision} =
               Decision.parse(%{
                 "action" => "start_episode",
                 "episode_ref" => candidate.ref,
                 "reaction" => nil,
                 "relation" => "history_only",
                 "reason" => "This appears to be new work with relevant history."
               })

      parent = self()
      blocker = episode_lock_task(old_id, parent)
      assert_receive {:episode_locked, blocker_backend}, 5_000

      reopener =
        unboxed_task(fn ->
          send(parent, {:reopen_started, self(), backend_pid()})

          Episodes.apply(%Command.AdmitInput{
            actor_ref: Input.actor_ref(input),
            destination: input.destination,
            episode_id: old_id,
            episode_key: old_key,
            linked_episode_id: nil,
            native_input_id: "reopen-source:#{old_id}",
            occurred_at: DateTime.add(@now, -1, :second),
            payload: Input.document(input),
            revision: 1,
            turn_ref: "turn-reopen:#{old_id}"
          })
        end)

      reopener_pid = reopener.pid
      assert_receive {:reopen_started, ^reopener_pid, reopener_backend}, 5_000
      await_blocked_by(reopener_backend, blocker_backend)

      commit =
        unboxed_task(fn ->
          send(parent, {:commit_started, self(), backend_pid()})
          Admission.commit(context, decision, "decision-reopen-serialization")
        end)

      commit_pid = commit.pid
      assert_receive {:commit_started, ^commit_pid, commit_backend}, 5_000

      try do
        await_blocked_by(commit_backend, reopener_backend)
        send(blocker.pid, :release)
        assert {:ok, _transition} = Task.await(reopener, 5_000)

        assert {:error, {:admission_rejected, :context_stale}} = Task.await(commit, 5_000)
        assert :error = Episodes.fetch_by_key("ingress-input:#{entry.id}")
      after
        send(blocker.pid, :release)
        stop_tasks([blocker, reopener, commit])
        Repo.delete_all(from(inbox in Entry, where: inbox.id == ^entry.id))

        case Repo.one(
               from(episode in Episode, where: episode.key == ^"ingress-input:#{entry.id}")
             ) do
          nil ->
            :ok

          episode ->
            Repo.delete_all(from(event in Event, where: event.episode_id == ^episode.id))
            Repo.delete_all(from(row in Episode, where: row.id == ^episode.id))
        end

        Repo.delete_all(from(event in Event, where: event.episode_id == ^old_id))
        Repo.delete_all(from(episode in Episode, where: episode.id == ^old_id))
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
    conversation_ref = input.destination.conversation_ref

    unboxed_task(fn ->
      Repo.transaction(fn ->
        Repo.query!(
          "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
          ["ingress-admission:#{input.destination.transport}:#{conversation_ref}"]
        )

        send(parent, {:conversation_locked, backend_pid()})

        receive do
          :release -> :ok
        end
      end)
    end)
  end

  defp episode_lock_task(episode_id, parent) do
    unboxed_task(fn ->
      Repo.transaction(fn ->
        Repo.one!(from(row in Episode, where: row.id == ^episode_id, lock: "FOR UPDATE"))

        send(parent, {:episode_locked, backend_pid()})

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
             SlackInput.new(%{
               actor: %{kind: :user, ref: "U123"},
               channel_ref: "C#{String.replace(suffix, "-", "")}",
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
