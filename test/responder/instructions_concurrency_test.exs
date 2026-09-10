defmodule Responder.InstructionsConcurrencyTest do
  use Responder.ConcurrencyCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Responder.Instructions
  alias Responder.Instructions.{Edit, Setting}
  alias Responder.Repo

  test "two first saves create one revision and return the winner to the stale editor" do
    Sandbox.unboxed_run(Repo, fn ->
      channel = "C" <> Base.encode16(:crypto.strong_rand_bytes(8))
      scope = {:channel, "TINSTRUCTIONS", channel}
      ref = "slack:TINSTRUCTIONS:#{channel}"
      observer = self()

      blocker =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
              "model-instructions:#{ref}"
            ])

            send(observer, {:scope_locked, backend_pid()})

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive {:scope_locked, blocking_backend}, 5_000

      contenders =
        for text <- ["First editor", "Second editor"] do
          unboxed_task(fn ->
            send(observer, {:editor_ready, self(), backend_pid()})
            Instructions.save(scope, text, 0, "control-plane:local")
          end)
        end

      try do
        for task <- contenders do
          pid = task.pid
          assert_receive {:editor_ready, ^pid, backend}, 5_000
          await_blocked_by(backend, blocking_backend)
        end

        send(blocker.pid, :release)
        results = Enum.map(contenders, &Task.await(&1, 5_000))
        assert [{:ok, saved}] = Enum.filter(results, &match?({:ok, _}, &1))

        assert [{:error, {:instructions_conflict, current}}] =
                 Enum.filter(results, &match?({:error, _}, &1))

        assert saved.text in ["First editor", "Second editor"]
        assert saved.revision == 1
        assert current == saved
        assert Instructions.get(scope) == saved
        assert Repo.aggregate(from(edit in Edit, where: edit.scope_ref == ^ref), :count) == 1
        assert {:ok, :ok} = Task.await(blocker, 5_000)
      after
        send(blocker.pid, :release)
        stop_tasks([blocker | contenders])
        Repo.delete_all(from(edit in Edit, where: edit.scope_ref == ^ref))
        Repo.delete_all(from(setting in Setting, where: setting.scope_ref == ^ref))
      end
    end)
  end
end
