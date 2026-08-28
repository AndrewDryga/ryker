defmodule Responder.Slack.InboxConcurrencyTest do
  use Responder.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Responder.Repo
  alias Responder.Slack.{Inbox, Input}
  alias Responder.Slack.Inbox.Entry

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
        Repo.delete_all(from(entry in Entry, where: entry.event_ref == ^event_ref))
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

  defp input!(event_ref) do
    assert {:ok, input} =
             Input.new(%{
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
