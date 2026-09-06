defmodule Responder.Ingress.InboxConcurrencyTest do
  use Responder.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Responder.Ingress.{Inbox, Input}
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Repo
  alias Responder.Slack.Input, as: SlackInput
  alias Responder.State.ConversationObservation

  test "simultaneous Slack retries converge on one inbox record" do
    Sandbox.unboxed_run(Repo, fn ->
      event_ref = "Ev-#{Ecto.UUID.generate()}"
      input = input!(event_ref)
      parent = self()
      blocker = lock_task(Input.dedupe_key(input), parent)
      assert_receive {:source_locked, blocker_backend}, 5_000

      contenders =
        Enum.map(1..2, fn _index ->
          unboxed_task(fn ->
            send(parent, {:contender_ready, self(), backend_pid()})
            Inbox.record(input)
          end)
        end)

      contender_backends =
        Enum.map(contenders, fn contender ->
          contender_pid = contender.pid
          assert_receive {:contender_ready, ^contender_pid, backend}, 5_000
          backend
        end)

      try do
        Enum.each(contender_backends, &await_blocked_by(&1, blocker_backend))
        send(blocker.pid, :release)

        statuses =
          contenders
          |> Enum.map(&Task.await(&1, 5_000))
          |> Enum.map(fn {:ok, receipt} -> receipt.status end)
          |> Enum.sort()

        assert statuses == [:duplicate, :recorded]

        assert Repo.aggregate(from(entry in Entry, where: entry.event_ref == ^event_ref), :count) ==
                 1
      after
        send(blocker.pid, :release)
        stop_tasks([blocker | contenders])
        delete_inputs!([event_ref])
      end
    end)
  end

  test "simultaneous executors cannot claim the same input" do
    Sandbox.unboxed_run(Repo, fn ->
      event_ref = "Ev-claim-#{Ecto.UUID.generate()}"
      input = input!(event_ref)
      assert {:ok, %{entry: entry}} = Inbox.record(input)
      parent = self()

      contenders =
        Enum.map(1..2, fn index ->
          unboxed_task(fn ->
            send(parent, {:claim_ready, self()})

            receive do
              :claim ->
                Inbox.claim_next("executor:#{index}", ~U[2026-08-27 12:00:00Z], 60)
            end
          end)
        end)

      try do
        Enum.each(contenders, fn contender ->
          contender_pid = contender.pid
          assert_receive {:claim_ready, ^contender_pid}, 5_000
        end)

        Enum.each(contenders, &send(&1.pid, :claim))
        results = Enum.map(contenders, &Task.await(&1, 5_000))

        claims = for {:ok, %{entry: claimed}} <- results, do: claimed
        idle = Enum.count(results, &(&1 == {:ok, nil}))

        assert Enum.map(claims, & &1.id) == [entry.id]
        assert idle == 1
      after
        stop_tasks(contenders)
        delete_inputs!([event_ref])
      end
    end)
  end

  defp lock_task(dedupe_key, parent) do
    unboxed_task(fn ->
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [dedupe_key])
        send(parent, {:source_locked, backend_pid()})

        receive do
          :release -> :ok
        end
      end)
    end)
  end

  test "simultaneous slots do not claim two pending inputs from the same conversation" do
    Sandbox.unboxed_run(Repo, fn ->
      refs = Enum.map(1..2, fn _ -> "Ev-ordered-#{Ecto.UUID.generate()}" end)

      entries =
        Enum.map(refs, fn ref ->
          {:ok, %{entry: entry}} = Inbox.record(input!(ref))
          entry
        end)

      parent = self()

      contenders =
        Enum.map(1..2, fn index ->
          unboxed_task(fn ->
            send(parent, {:ordered_ready, self()})

            receive do
              :claim -> Inbox.claim_next("ordered-slot:#{index}", DateTime.utc_now(), 60)
            end
          end)
        end)

      try do
        Enum.each(contenders, fn task ->
          pid = task.pid
          assert_receive {:ordered_ready, ^pid}, 5_000
        end)

        Enum.each(contenders, &send(&1.pid, :claim))
        results = Enum.map(contenders, &Task.await(&1, 5_000))
        claims = for {:ok, %{entry: claimed}} <- results, do: claimed.id
        assert claims == [hd(entries).id]
        assert Enum.count(results, &(&1 == {:ok, nil})) == 1
      after
        stop_tasks(contenders)
        delete_inputs!(refs)
      end
    end)
  end

  defp delete_inputs!(refs) do
    inputs = from(entry in Entry, where: entry.event_ref in ^refs)
    ids = from(entry in inputs, select: entry.id)

    Repo.delete_all(
      from(note in ConversationObservation, where: note.source_input_id in subquery(ids))
    )

    Repo.delete_all(inputs)
  end

  defp input!(event_ref) do
    assert {:ok, input} =
             SlackInput.new(%{
               actor: %{kind: :app, ref: "A123"},
               channel_ref: "C456",
               content: %{"text" => "A concurrently delivered Slack event"},
               event_kind: :message,
               event_ref: event_ref,
               message_ref: "1787832000.000100",
               occurred_at: ~U[2026-08-27 12:00:00Z],
               revision: 1,
               thread_ref: nil,
               workspace_ref: "T123"
             })

    input
  end
end
