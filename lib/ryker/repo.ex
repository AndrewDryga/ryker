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
end
