defmodule Ryker.StateTools.BindingConcurrencyTest do
  # A state tool holds its session while it runs, for seconds when it checks memory, and the
  # foreign key of every activity row takes a key lock on it. `FOR UPDATE` conflicts with that
  # lock, so the worker's narration of a turn queued behind the turn's own tools (2026-11-03).
  # `FOR NO KEY UPDATE` still keeps tools and bookkeeping apart.
  use Ryker.ConcurrencyCase, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Fixtures.Personalization
  alias Ryker.Knowledge.KnowledgeSnapshot
  alias Ryker.Repo
  alias Ryker.StateTools.Binding
  alias Ryker.Work.Session

  test "a state tool holding its session lets activity be recorded beside it" do
    holds_session_while(&lock_through_binding/1)
  end

  # A tool that discloses memory takes the same row again, and a stronger lock there would make
  # the tool wait on a worker's event batch after it had already read the memory.
  test "a state tool disclosing memory lets activity be recorded beside it" do
    holds_session_while(&lock_through_disclosure/1)
  end

  defp lock_through_binding(binding) do
    assert {:ok, _current} = Binding.fetch_and_lock_current(binding)
  end

  defp lock_through_disclosure(binding) do
    assert KnowledgeSnapshot.expose(binding, []) == :ok
  end

  defp holds_session_while(lock) do
    Sandbox.unboxed_run(Repo, fn ->
      {claim, _source} = Personalization.preference_context!()
      binding = %{episode: claim.episode, session: claim.session, turn: claim.turn}
      tool = tool_holding(lock, binding)

      try do
        assert_receive {:held, tool_backend}, 5_000
        assert {:ok, %{num_rows: 1}} = take_foreign_key_lock(claim.session.id)

        bookkeeping = bookkeeping_on(claim.session.id)
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

  defp tool_holding(lock, binding) do
    parent = self()

    unboxed_task(fn ->
      Repo.transaction(fn ->
        lock.(binding)
        send(parent, {:held, backend_pid()})
        receive do: (:release -> :ok)
      end)
    end)
  end

  # The lock an activity row's foreign key takes.
  defp take_foreign_key_lock(session_id) do
    Repo.transaction(fn ->
      Repo.query!("SET LOCAL lock_timeout = '500ms'")

      Repo.query!("SELECT 1 FROM episode_work_sessions WHERE id = $1 FOR KEY SHARE", [
        Ecto.UUID.dump!(session_id)
      ])
    end)
  end

  defp bookkeeping_on(session_id) do
    parent = self()

    unboxed_task(fn ->
      send(parent, {:bookkeeping, backend_pid()})

      Repo.transaction(fn ->
        session_id |> Session.Query.by_id() |> Session.Query.lock_for_update() |> Repo.one!()
        :ok
      end)
    end)
  end
end
