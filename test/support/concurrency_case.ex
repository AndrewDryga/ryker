defmodule Ryker.ConcurrencyCase do
  @moduledoc false
  use ExUnit.CaseTemplate
  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Behaviors.StandingRuleInventory
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Learning.ConversationObservation
  alias Ryker.People.FactWithdrawal
  alias Ryker.Repo

  using do
    quote do
      @moduletag :database
      import Ecto.Query
      import Ryker.ConcurrencyCase
    end
  end

  # An unboxed test commits for real, so it runs only in a database its run
  # owns. In the shared ryker_test, a run killed or failed before its cleanup
  # left its episode to every later run, whose claim tests claimed it instead
  # of their own work: 219 of 404 tests failed there on 2026-11-20 from one
  # episode left the day before, the pre-commit hook's included.
  # scripts/elixir-test.sh gives a run that names such a file a database of
  # its own.
  setup_all %{module: module} do
    unless exclusive_database?() do
      raise "#{inspect(module)} commits for real, so it runs only in a database its run " <>
              "owns, not #{Repo.config()[:database]}; scripts/elixir-test.sh gives it one"
    end

    :ok
  end

  # A row an unboxed test forgets outlives it: every later test that needs an
  # empty database refuses to start, far from the cause. Nineteen such
  # failures in a dev-check on 2026-09-11, and 67 in `make check` on
  # 2026-09-28 from one withdrawn case. So the test that left a row fails and
  # names its table.
  setup do
    before = committed_rows()
    on_exit(fn -> assert_no_rows_left!(before) end)
    :ok
  end

  defp exclusive_database?, do: exclusive_database?(Repo.config()[:database] || "")

  @doc """
  Deletes what `cleanup` names once the test ends, however it ends.

  Register it before the first committing write: a failure before a test's
  `try`, or a test killed at its timeout, skips that `after`, and ExUnit runs
  `on_exit` either way. An episode a custody test left in staged setup on
  2026-11-19 was claimed by every claim test after it.
  """
  def clean_up_on_exit(cleanup) do
    on_exit(fn -> Sandbox.unboxed_run(Repo, cleanup) end)
  end

  # `scripts/elixir-test.sh` names an isolated database ryker_test_<pid>_<n>,
  # and a gate partition's ryker_test_<pid>_<n>_p<k>; the shared ryker_test may
  # hold other runs' committed rows at any moment. The partition names went
  # unmatched from 2026-10-02, so no gate checked for left rows (2026-10-04
  # review), and a claim test later counted a turn some test had left.
  @doc false
  def exclusive_database?(name),
    do: Regex.match?(~r/\Aryker_test_\d+_\d+(_p\d+)?\z/, name)

  defp committed_rows do
    Sandbox.unboxed_run(Repo, fn ->
      %{rows: tables} =
        Repo.query!("""
        SELECT table_name FROM information_schema.tables
        WHERE table_schema = current_schema() AND table_type = 'BASE TABLE'
        ORDER BY table_name
        """)

      counts =
        Enum.map_join(tables, " UNION ALL ", fn [table] ->
          "SELECT '#{table}', count(*) FROM \"#{table}\""
        end)

      Repo.query!(counts).rows |> Map.new(fn [table, count] -> {table, count} end)
    end)
  end

  defp assert_no_rows_left!(before) do
    left =
      for {table, count} <- committed_rows(),
          count > Map.get(before, table, 0),
          do: "#{table} +#{count - Map.get(before, table, 0)}"

    if left != [] do
      raise ExUnit.AssertionError,
        message:
          "the test left committed rows: #{Enum.join(left, ", ")}; delete them in its cleanup"
    end
  end

  def unboxed_task(fun) do
    Task.async(fn ->
      Process.delete(:"$callers")
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        fun.()
      after
        :ok = Sandbox.checkin(Repo)
      end
    end)
  end

  @doc """
  Deletes committed inbox entries together with the evidence keyed by them.

  Unboxed tests commit for real and own their cleanup. Observations and
  standing-rule inventories reference the entry without a foreign key, so an
  entry deleted on its own strands them, and the next test that needs an empty
  database (the learning runner preflight) fails on rows no sandbox can see.
  Nineteen such failures in one dev-check on 2026-09-11.
  """
  def delete_entries!(entry_query) do
    entries = Repo.all(entry_query)
    ids = Enum.map(entries, & &1.id)
    messages = Enum.map(entries, & &1.native_input_id)
    Repo.delete_all(from(w in FactWithdrawal, where: w.source_message_ref in ^messages))
    refs = Enum.map(entries, &Inbox.ref/1)

    Repo.delete_all(from(note in ConversationObservation, where: note.source_input_id in ^ids))

    Repo.delete_all(
      from(inventory in StandingRuleInventory, where: inventory.source_input_ref in ^refs)
    )

    Repo.delete_all(from(entry in Entry, where: entry.id in ^ids))
  end

  def backend_pid do
    %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
    pid
  end

  def await_blocked_by(blocked_backend, blocking_backend, deadline \\ deadline()) do
    query = "SELECT $2::integer = ANY(pg_blocking_pids($1::integer))"

    cond do
      Repo.query!(query, [blocked_backend, blocking_backend]).rows == [[true]] ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("backend #{blocked_backend} never waited on #{blocking_backend}")

      true ->
        await_blocked_by(blocked_backend, blocking_backend, deadline)
    end
  end

  @doc """
  Waits until `task` has finished or its backend waits on `blocking_backend`,
  without taking the task's reply: release the blocker, then await the task.
  """
  def await_finished_or_blocked(task, backend, blocking_backend, deadline \\ deadline()) do
    query = "SELECT $2::integer = ANY(pg_blocking_pids($1::integer))"

    cond do
      not Process.alive?(task.pid) ->
        :finished

      Repo.query!(query, [backend, blocking_backend]).rows == [[true]] ->
        :waiting

      System.monotonic_time(:millisecond) > deadline ->
        flunk("backend #{backend} neither finished nor waited on #{blocking_backend}")

      true ->
        await_finished_or_blocked(task, backend, blocking_backend, deadline)
    end
  end

  @doc "Waits until `blocked_backend` waits on any of `possible_blockers`."
  def await_blocked_by_any(blocked_backend, possible_blockers, deadline \\ deadline()) do
    %{rows: [[blocking_backends]]} =
      Repo.query!("SELECT pg_blocking_pids($1::integer)", [blocked_backend])

    cond do
      Enum.any?(blocking_backends, &(&1 in possible_blockers)) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("backend #{blocked_backend} never waited on any of #{inspect(possible_blockers)}")

      true ->
        await_blocked_by_any(blocked_backend, possible_blockers, deadline)
    end
  end

  def stop_tasks(tasks) do
    Enum.each(tasks, fn task ->
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    end)
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
end
