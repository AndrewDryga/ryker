defmodule Ryker.CoopFleet do
  @moduledoc """
  What the console asks of the Coop fleet: how often a worker reports in, the
  bound it judges a worker lost by. Forwards to `Ryker.CoopFleet.Worker`, so
  the console never reaches below this one
  (`Ryker.Checks.WebNoNestedDomainCalls`).
  """
  alias Ryker.CoopFleet.Worker

  @doc "Seconds between a Coop worker's heartbeats."
  @spec worker_heartbeat_seconds() :: pos_integer()
  defdelegate worker_heartbeat_seconds(), to: Worker, as: :heartbeat_seconds
end
