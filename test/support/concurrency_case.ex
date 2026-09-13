defmodule Ryker.ConcurrencyCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  import Ecto.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias Ryker.Ingress.Inbox
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.State.{ConversationObservation, StandingRuleInventory}

  using do
    quote do
      @moduletag :database
      import Ecto.Query
      import Ryker.ConcurrencyCase
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

  def stop_tasks(tasks) do
    Enum.each(tasks, fn task ->
      if Process.alive?(task.pid), do: Task.shutdown(task, :brutal_kill)
    end)
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5_000
end
