defmodule Ryker.CoopFleet.Machine do
  @moduledoc false
  alias Ryker.CoopFleet.ControlPlane.Shared
  alias Ryker.Maps

  @maximum 9_223_372_036_854_775_807
  @fields ~w(daemon cpu_millis memory_bytes free_cpu_millis free_memory_bytes)
  def validate(nil), do: :ok

  def validate(%{} = report) do
    if Maps.exact_keys?(report, @fields) and
         is_binary(report["daemon"]) and Regex.match?(~r/\A[0-9a-f]{64}\z/, report["daemon"]) and
         positive?(report["cpu_millis"]) and positive?(report["memory_bytes"]) and
         free?(report["free_cpu_millis"], report["cpu_millis"]) and
         free?(report["free_memory_bytes"], report["memory_bytes"]) do
      :ok
    else
      {:error, {:invalid_coop_worker_protocol, :machine}}
    end
  end

  def validate(_report), do: {:error, {:invalid_coop_worker_protocol, :machine}}

  # A restarted connector must complete negotiation before it sends its first
  # report. Accept that poll while holding new placements, never downgrade.
  def heartbeat(worker, capacity, negotiated) do
    daemon = get_in(capacity, ["machine", "daemon"])

    if daemon && worker.machine_daemon && daemon != worker.machine_daemon,
      do: Shared.rollback({:coop_worker_machine_changed, worker.id})

    %{
      machine_daemon: daemon || worker.machine_daemon,
      machine_report_required: worker.machine_report_required or negotiated or not is_nil(daemon)
    }
  end

  def available?(%{machine_report_required: true, capacity: capacity}),
    do: is_map(capacity["machine"])

  def available?(_worker), do: true
  defp positive?(value), do: is_integer(value) and value in 1..@maximum
  defp free?(value, total), do: is_integer(value) and value >= 0 and value <= total
end
