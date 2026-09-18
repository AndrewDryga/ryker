defmodule Ryker.Repo do
  use Ecto.Repo,
    adapter: Ecto.Adapters.Postgres,
    otp_app: :ryker

  @doc """
  The database's own clock at this instant, microsecond precision.

  Custody compares leases, placements and receipts against this rather than
  the VM clock so one writer's fences agree across restarts and hosts.
  """
  @spec now!() :: DateTime.t()
  def now! do
    %{rows: [[%DateTime{} = now]]} = query!("SELECT clock_timestamp()")
    now
  end

  @conflicts [:serialization_failure, :deadlock_detected]
  @exhausted [:query_canceled, :lock_not_available | @conflicts]

  @doc """
  Whether PostgreSQL refused a transaction because a concurrent one won.

  The snapshot it read is stale, and reading again may succeed.
  """
  @spec conflict?(Exception.t()) :: boolean()
  def conflict?(%Postgrex.Error{postgres: %{code: code}}), do: code in @conflicts
  def conflict?(_error), do: false

  @doc """
  Whether a bounded read gave up: its statement or lock timeout ran out, or
  it lost a conflict.
  """
  @spec budget_exhausted?(Exception.t()) :: boolean()
  def budget_exhausted?(%Postgrex.Error{postgres: %{code: code}}), do: code in @exhausted
  def budget_exhausted?(_error), do: false
end
