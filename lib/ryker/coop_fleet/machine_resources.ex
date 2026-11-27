defmodule Ryker.CoopFleet.MachineResources do
  @moduledoc false
  alias Ryker.CoopFleet.{Command, Placement, Worker}
  alias Ryker.Repo
  alias Ryker.Retention

  def creating_since(now), do: DateTime.add(now, -300, :second)

  def fits?(%{capacity: %{"machine" => %{} = machine}} = worker, session, since) do
    allocations = worker.id |> Placement.Query.unbound_allocations(session.id) |> Repo.all()

    {slots, pending_cpu, pending_memory} =
      Enum.reduce(allocations, {0, 0, 0}, fn {placement, at, owner}, totals ->
        if held?(placement, owner, DateTime.after?(at, since)) do
          reserve(owner.worker_job_document, totals, machine)
        else
          totals
        end
      end)

    {cpu, memory} = request(session.worker_job_document, machine)

    slots_free?(worker, slots) and cpu <= machine["free_cpu_millis"] - pending_cpu and
      memory <= machine["free_memory_bytes"] - pending_memory
  end

  def fits?(worker, _session, since) do
    reserved =
      worker.id
      |> Placement.Query.unbound_since(since)
      |> Placement.Query.without_closed_session()
      |> Repo.aggregate(:count)

    Ryker.CoopFleet.Machine.available?(worker) and slots_free?(worker, reserved)
  end

  defp slots_free?(worker, reserved) do
    Enum.all?(
      ~w(session turn workspace),
      &(Map.get(worker.capacity, "#{&1}_slots_free", 0) > reserved)
    )
  end

  # The worker lock serializes a late submit with capacity allocated since
  # its placement. Replays return their existing receipt before reaching here.
  def verify_enqueue!(placement, session, kind, payload) do
    if creates?(kind, payload), do: verify_create!(placement, session)
    :ok
  end

  defp verify_create!(placement, session) do
    worker = Repo.fetch!(Worker.Query.by_id(placement.worker_id))

    if worker.machine_report_required and
         not fits?(worker, session, creating_since(Repo.now!())) do
      Repo.rollback({:coop_worker_capacity_unavailable, session.id})
    end
  end

  defp held?(placement, owner, fresh?) do
    query = Command.Query.by_placement_id(placement)
    canonical = Command.Query.by_kind(query, "create_session")

    cond do
      Repo.exists?(Command.Query.raw_session_creates(query)) -> true
      Repo.exists?(canonical) -> Retention.Creation.resolve(owner) != {:ok, :absent}
      true -> fresh?
    end
  end

  defp creates?("create_session", _payload), do: true
  defp creates?("api_request", %{"method" => "POST", "path" => "/v1/sessions"}), do: true
  defp creates?(_kind, _payload), do: false

  defp reserve(job, {slots, cpu, memory}, machine) do
    {next_cpu, next_memory} = request(job, machine)
    {slots + 1, cpu + next_cpu, memory + next_memory}
  end

  defp request(%{"resources" => %{"cpu_millis" => cpu, "memory_bytes" => memory}} = job, machine) do
    runtime = Map.get(job, "runtime", %{})
    services = runtime["max_services"]

    cond do
      runtime["compose"] not in [nil, ""] and services in [nil, 0] ->
        entire(machine)

      is_integer(services) and services in 0..64 ->
        {cpu * (1 + services), memory * (1 + services)}

      true ->
        {cpu, memory}
    end
  end

  defp request(_unknown, machine), do: entire(machine)
  defp entire(machine), do: {machine["cpu_millis"], machine["memory_bytes"]}
end
