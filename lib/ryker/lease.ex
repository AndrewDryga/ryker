defmodule Ryker.Lease do
  @moduledoc """
  The lease a lane's worker holds on a row while it works on it. The row names
  its lease (`lease_ref`) and when it runs out (`lease_expires_at`), both read
  against the database clock (`Ryker.Repo.now!/0`), and the database keeps the
  lease's ref, owner and expiry set or cleared together.

  Each custody had its own copy of these two rules (2026-10-04 review).
  """

  @doc """
  Whether `lease_ref` holds `row`'s lease at `now`: it is the row's lease, and
  it has not run out. A row without a lease is held by nobody.
  """
  @spec held?(map(), term(), DateTime.t()) :: boolean()
  def held?(%{lease_ref: held, lease_expires_at: expires_at}, lease_ref, now),
    do: held?(held, expires_at, lease_ref, now)

  @doc "`held?/3` for a lease kept under other field names."
  @spec held?(term(), term(), term(), DateTime.t()) :: boolean()
  def held?(lease_ref, %DateTime{} = expires_at, lease_ref, %DateTime{} = now)
      when is_binary(lease_ref),
      do: DateTime.compare(expires_at, now) == :gt

  def held?(_held, _expires_at, _lease_ref, _now), do: false

  @doc """
  When a lease that ran out at `expires_at` runs out once renewed at `now` for
  `seconds`: never sooner than it already did.
  """
  @spec renewed(DateTime.t() | nil, DateTime.t(), pos_integer()) :: DateTime.t()
  def renewed(expires_at, now, seconds) do
    requested = DateTime.add(now, seconds, :second)

    if is_struct(expires_at, DateTime) and DateTime.compare(expires_at, requested) == :gt,
      do: expires_at,
      else: requested
  end
end
