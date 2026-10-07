defmodule Ryker.AdvisoryLockTest do
  # One module holds every advisory lock Ryker takes; twenty-two places spelled
  # the statement by hand until 2026-10-07. A lock serializes only while every
  # holder computes the same key from the same name, so these hold the key a
  # name hashes to, the mode, and how long each kind of lock lasts.
  use ExUnit.Case, async: true
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.{AdvisoryLock, Repo}

  setup do
    :ok = Sandbox.checkout(Repo)
  end

  test "a named lock is held at its name's hash until the transaction ends, alone or shared" do
    {:ok, held} =
      Repo.transaction(fn ->
        :ok = AdvisoryLock.hold!("advisory-lock-test:alone")
        :ok = AdvisoryLock.hold!("advisory-lock-test:shared", :shared)
        :ok = AdvisoryLock.hold(91_000_017)
        held_locks()
      end)

    assert held ==
             [
               {hashed("advisory-lock-test:alone"), "ExclusiveLock"},
               {hashed("advisory-lock-test:shared"), "ShareLock"},
               {91_000_017, "ExclusiveLock"}
             ]
             |> Enum.sort()
  end

  test "a session lock is taken by one session at a time until it is released" do
    key = System.unique_integer([:positive]) + 91_000_000
    parent = self()

    assert AdvisoryLock.try_session(key)

    other =
      Task.async(fn ->
        :ok = Sandbox.checkout(Repo)
        send(parent, {:while_held, AdvisoryLock.try_session(key)})

        receive do
          :released -> AdvisoryLock.try_session(key) and AdvisoryLock.release_session(key) == :ok
        end
      end)

    assert_receive {:while_held, false}, 5_000
    assert AdvisoryLock.release_session(key) == :ok
    send(other.pid, :released)
    assert Task.await(other, 5_000)
  end

  defp held_locks do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT (classid::bigint << 32) | objid::bigint, mode
        FROM pg_locks
        WHERE locktype = 'advisory' AND pid = pg_backend_pid() AND granted
        ORDER BY 1, 2
        """,
        []
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  defp hashed(name) do
    %{rows: [[key]]} = Repo.query!("SELECT hashtextextended($1, 0)", [name])
    key
  end
end
