defmodule Ryker.Publication.Callback do
  @moduledoc false

  def start(result_ref, function) do
    caller = self()
    spawn_monitor(fn -> supervise(caller, result_ref, function) end)
  end

  def finish(pid, monitor, result_ref) do
    # The caller may survive a raised renewal, or may already have consumed its
    # original monitor. Wait for the guardian to reap its callback in either case.
    cleanup_monitor = Process.monitor(pid)
    send(pid, {:cancel_callback, self(), result_ref})
    receive do: ({:DOWN, ^cleanup_monitor, :process, ^pid, _reason} -> :ok)
    Process.demonitor(monitor, [:flush])

    receive do
      {^result_ref, _result} -> :ok
    after
      0 -> :ok
    end
  end

  defp supervise(caller, result_ref, function) do
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(caller)
    guardian = self()

    callback =
      spawn_link(fn ->
        send(guardian, {:callback_result, self(), function.()})
      end)

    try do
      receive do
        {:callback_result, ^callback, result} ->
          send(caller, {result_ref, result})

        {:EXIT, ^callback, reason} ->
          exit(reason)

        {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
          :ok

        {:cancel_callback, ^caller, ^result_ref} ->
          :ok
      end
    after
      # A brutal caller death skips its own after block. This independent
      # guardian still stops the callback before its own lifetime ends.
      callback_monitor = Process.monitor(callback)
      Process.exit(callback, :kill)
      receive do: ({:DOWN, ^callback_monitor, :process, ^callback, _reason} -> :ok)
    end
  end
end
