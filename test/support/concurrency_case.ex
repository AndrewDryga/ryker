defmodule Responder.ConcurrencyCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox
  alias Responder.Repo

  using do
    quote do
      @moduletag :database
      import Ecto.Query
      import Responder.ConcurrencyCase
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
