defmodule Ryker.StateTools.BindingConcurrencyTest do
  # A state tool holds its session while it runs, for seconds when it checks memory, and the
  # foreign key of every activity row takes a key lock on it. `FOR UPDATE` conflicts with that
  # lock, so the worker's narration of a turn queued behind the turn's own tools (2026-11-03).
  # `FOR NO KEY UPDATE` still keeps tools and bookkeeping apart.
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Fixtures.Personalization
  alias Ryker.Repo
  alias Ryker.StateTools.Binding
  alias Ryker.Work.Session

  test "a state tool holding its session lets activity be recorded beside it" do
    Sandbox.unboxed_run(Repo, fn ->
      {claim, _source} = Personalization.preference_context!()
      parent = self()
      binding = %{episode: claim.episode, session: claim.session, turn: claim.turn}

      tool =
        unboxed_task(fn ->
          Repo.transaction(fn ->
            assert {:ok, _current} = Binding.fetch_and_lock_current(binding)
            send(parent, {:held, backend_pid()})
            receive do: (:release -> :ok)
          end)
        end)

      try do
        assert_receive {:held, tool_backend}, 5_000

        # The lock an activity row's foreign key takes.
        assert {:ok, %{num_rows: 1}} =
                 Repo.transaction(fn ->
                   Repo.query!("SET LOCAL lock_timeout = '500ms'")

                   Repo.query!(
                     "SELECT 1 FROM episode_work_sessions WHERE id = $1 FOR KEY SHARE",
                     [
                       Ecto.UUID.dump!(claim.session.id)
                     ]
                   )
                 end)

        bookkeeping =
          unboxed_task(fn ->
            send(parent, {:bookkeeping, backend_pid()})

            Repo.transaction(fn ->
              claim.session.id
              |> Session.Query.by_id()
              |> Session.Query.lock_for_update()
              |> Repo.one!()

              :ok
            end)
          end)

        assert_receive {:bookkeeping, backend}, 5_000
        await_blocked_by(backend, tool_backend)
        send(tool.pid, :release)
        assert Task.await(bookkeeping, 5_000) == {:ok, :ok}
      after
        send(tool.pid, :release)
        stop_tasks([tool])
        Personalization.cleanup!(claim)
      end
    end)
  end
end
