defmodule Responder.Admission.LeaseRenewerTest do
  use ExUnit.Case, async: true

  alias Responder.Admission.LeaseRenewer

  test "many fast Coop polls renew the durable lease at a bounded cadence" do
    {:ok, clock} = Agent.start_link(fn -> ~U[2026-08-27 12:00:00.000000Z] end)
    {:ok, renewals} = Agent.start_link(fn -> [] end)
    now = fn -> Agent.get(clock, & &1) end

    renew = fn renewed_at ->
      Agent.update(renewals, &[renewed_at | &1])
      :ok
    end

    heartbeat = LeaseRenewer.new(now.(), 300, now, renew)

    for _poll <- 1..2_000, do: assert(:ok = heartbeat.())
    assert Agent.get(renewals, &length/1) == 0

    Agent.update(clock, &DateTime.add(&1, 100, :second))
    for _poll <- 1..2_000, do: assert(:ok = heartbeat.())
    assert Agent.get(renewals, &length/1) == 1

    Agent.update(clock, &DateTime.add(&1, 99, :second))
    for _poll <- 1..2_000, do: assert(:ok = heartbeat.())
    assert Agent.get(renewals, &length/1) == 1

    Agent.update(clock, &DateTime.add(&1, 1, :second))
    assert :ok = heartbeat.()
    assert Agent.get(renewals, &length/1) == 2
  end
end
