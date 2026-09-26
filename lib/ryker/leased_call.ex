defmodule Ryker.LeasedCall do
  @moduledoc """
  Calls out to a provider while holding a durable lease.

  The call runs in its own process under a guardian that stops it when the
  caller dies: a caller killed outright runs no cleanup of its own, and a call
  that outlived it could still act after another worker reclaimed the lease.

  While the call runs, the lease is renewed every third of its lifetime, so a
  slow provider keeps custody. When the call answers, the lease is renewed once
  more, so the caller records the answer under the lease it claimed. A renewal
  that fails ends the call and returns the renewal's error instead.

  Whatever happens, the call is stopped and its late answer drained before
  `run/4` returns, even when a renewal raises: a caller that survives the raise,
  as a poller backing off a database outage does, is left no stray process and
  no stray message.
  """

  @doc """
  Runs `call` in its own process while `renew` keeps the lease.

  `renew` answers `{:ok, _}` or `{:error, reason}`. A call that dies before it
  answers, or whose guardian dies, answers `{:error, {exit_tag, reason}}`;
  a call that can raise should catch its own errors in the shape its caller
  records.
  """
  @spec run((-> result), (-> {:ok, term()} | {:error, term()}), pos_integer(), atom()) ::
          result | {:error, term()}
        when result: term()
  def run(call, renew, lease_seconds, exit_tag) do
    caller = self()
    result_ref = make_ref()
    {guardian, monitor} = spawn_monitor(fn -> guard(caller, result_ref, call, exit_tag) end)
    cadence_ms = max(div(lease_seconds * 1_000, 3), 1)

    try do
      await(result_ref, guardian, monitor, renew, cadence_ms, exit_tag)
    after
      stop(result_ref, guardian, monitor)
    end
  end

  defp guard(caller, result_ref, call, exit_tag) do
    Process.flag(:trap_exit, true)
    caller_monitor = Process.monitor(caller)
    guardian = self()
    worker = spawn_link(fn -> send(guardian, {:leased_call_result, self(), call.()}) end)

    try do
      receive do
        {:leased_call_result, ^worker, result} ->
          send(caller, {result_ref, result})

        {:EXIT, ^worker, reason} ->
          send(caller, {result_ref, {:error, {exit_tag, reason}}})

        {:DOWN, ^caller_monitor, :process, ^caller, _reason} ->
          :ok

        {:cancel_leased_call, ^caller, ^result_ref} ->
          :ok
      end
    after
      # A brutal caller death skips its own after block. This independent
      # guardian still stops the call before its own lifetime ends.
      worker_monitor = Process.monitor(worker)
      Process.exit(worker, :kill)
      receive do: ({:DOWN, ^worker_monitor, :process, ^worker, _reason} -> :ok)
    end
  end

  defp await(result_ref, guardian, monitor, renew, cadence_ms, exit_tag) do
    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor, [:flush])

        case renewed(renew) do
          :ok -> result
          {:error, _reason} = error -> error
        end

      {:DOWN, ^monitor, :process, ^guardian, reason} ->
        {:error, {exit_tag, reason}}
    after
      cadence_ms ->
        case renewed(renew) do
          :ok -> await(result_ref, guardian, monitor, renew, cadence_ms, exit_tag)
          {:error, _reason} = error -> error
        end
    end
  end

  defp renewed(renew) do
    case renew.() do
      {:ok, _renewed} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # The caller may survive a raised renewal, or may already have consumed its
  # original monitor. Wait for the guardian to reap the call in either case,
  # then drain the answer it may have sent meanwhile.
  defp stop(result_ref, guardian, monitor) do
    cleanup_monitor = Process.monitor(guardian)
    send(guardian, {:cancel_leased_call, self(), result_ref})
    receive do: ({:DOWN, ^cleanup_monitor, :process, ^guardian, _reason} -> :ok)
    Process.demonitor(monitor, [:flush])

    receive do
      {^result_ref, _result} -> :ok
    after
      0 -> :ok
    end
  end
end
