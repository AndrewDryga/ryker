defmodule Ryker.CoopFleet do
  @moduledoc """
  What the console asks of the Coop fleet: how often a worker reports in, the
  bound it judges a worker lost by. Forwards to `Ryker.CoopFleet.Worker`, so
  the console never reaches below this one
  (`Ryker.Checks.WebNoNestedDomainCalls`).
  """
  alias Ryker.CoopFleet.PresetCatalog
  alias Ryker.CoopFleet.Worker
  alias Ryker.Repo

  @doc "Approved model presets available to the installation's selected accounts."
  defdelegate model_presets(accounts), to: PresetCatalog, as: :choices

  @doc "Seconds between a Coop worker's heartbeats."
  @spec worker_heartbeat_seconds() :: pos_integer()
  defdelegate worker_heartbeat_seconds(), to: Worker, as: :heartbeat_seconds

  @doc """
  What each enrolled worker's providers last reported about its accounts'
  allowance (`Ryker.CoopFleet.AccountUsage`), as `%{worker_id, last_seen_at,
  accounts}`, the most recently seen worker first.
  """
  @spec account_usage_reports() :: [map()]
  def account_usage_reports do
    Worker.Query.reporting_account_usage()
    |> Repo.all()
    |> Enum.map(fn worker ->
      %{
        worker_id: worker.id,
        last_seen_at: worker.last_seen_at,
        accounts: worker.account_usage["accounts"]
      }
    end)
  end
end
