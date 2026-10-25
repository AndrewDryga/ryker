defmodule Ryker.Memories.ForgettingConfirmationConcurrencyTest do
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Fixtures.MemoryConfirmations
  alias Ryker.Memories
  alias Ryker.Repo

  # A renderer or POST read cannot authorize the row after waiting for the
  # review lock: an edit can replace its words before Forget obtains it.
  test "an edit committed while Forget waits preserves its unconfirmed words" do
    Sandbox.unboxed_run(Repo, fn ->
      context = MemoryConfirmations.current!()
      parent = self()

      try do
        editor =
          unboxed_task(fn ->
            Repo.transaction(fn ->
              Memories.lock_reviews_in_transaction()
              send(parent, {:editor_locked, backend_pid()})
              receive do: (:replace -> :ok)
              MemoryConfirmations.edit!(context, context.replacement)
              :ok
            end)
          end)

        try do
          assert_receive {:editor_locked, blocking}, 5_000

          forgetter =
            unboxed_task(fn ->
              send(parent, {:forget_started, backend_pid()})
              Memories.forget(context.memory.ref, context.memory.payload_fingerprint)
            end)

          try do
            assert_receive {:forget_started, backend}, 5_000
            await_blocked_by(backend, blocking)
            send(editor.pid, :replace)
            assert Task.await(editor, 5_000) == {:ok, :ok}
            result = Task.await(forgetter, 5_000)
            memory = MemoryConfirmations.fetch!(context)

            assert memory.status == :active
            assert memory.subject == context.replacement["subject"]
            assert memory.payload["value"] == context.replacement["value"]
            assert result == {:error, :confirmation_stale}
          after
            stop_tasks([forgetter])
          end
        after
          send(editor.pid, :replace)
          stop_tasks([editor])
        end
      after
        MemoryConfirmations.cleanup!(context)
      end
    end)
  end
end
