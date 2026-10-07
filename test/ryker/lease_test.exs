defmodule Ryker.LeaseTest do
  use ExUnit.Case, async: true
  alias Ryker.Lease

  @now ~U[2026-10-07 12:00:00.000000Z]

  # Every custody checked a held lease with its own copy of the rule
  # (2026-10-04 review). A row with no lease must not count as held by a
  # caller that holds none either: nil equals nil.
  test "a lease is held by its own ref only, and only until it runs out" do
    row = %{lease_ref: "lease:one", lease_expires_at: DateTime.add(@now, 1, :second)}

    assert Lease.held?(row, "lease:one", @now)
    refute Lease.held?(row, "lease:two", @now)
    refute Lease.held?(%{row | lease_expires_at: @now}, "lease:one", @now)
    refute Lease.held?(%{lease_ref: nil, lease_expires_at: nil}, nil, @now)

    assert Lease.held?("lease:one", row.lease_expires_at, "lease:one", @now)
    refute Lease.held?("lease:one", nil, "lease:one", @now)
  end

  test "a renewal never shortens a lease" do
    later = DateTime.add(@now, 300, :second)

    assert Lease.renewed(nil, @now, 60) == DateTime.add(@now, 60, :second)
    assert Lease.renewed(@now, @now, 60) == DateTime.add(@now, 60, :second)
    assert Lease.renewed(later, @now, 60) == later
  end
end
