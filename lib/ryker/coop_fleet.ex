defmodule Ryker.CoopFleet do
  @moduledoc """
  What the console asks of the Coop fleet: how often a worker reports in, the
  bound it judges a worker lost by. Forwards to `Ryker.CoopFleet.Worker`, so
  the console never reaches below this one
  (`Ryker.Checks.WebNoNestedDomainCalls`).
  """
  alias Ryker.Bootstrap
  alias Ryker.CoopFleet.{Enrollment, PresetCatalog, Worker}
  alias Ryker.Repo

  @doc "Approved model presets available to the installation's selected accounts."
  defdelegate model_presets(accounts), to: PresetCatalog, as: :choices

  @doc """
  Where a worker someone runs themselves connects, and the certificate authority it must
  trust: `%{controller_url, ca_pem}` for Settings › Advanced's steps, or nil when this
  installation takes no workers of its own (no worker gateway, or no address workers reach it at).
  """
  @spec worker_connection() :: %{controller_url: String.t(), ca_pem: String.t()} | nil
  # The operator names the certificate file in RYKER_WORKER_CA_FILE, an absolute path the
  # gateway itself serves from; nothing a person sends reaches it.
  # sobelow_skip ["Traversal.FileModule"]
  def worker_connection do
    with %{public_url: url, cacertfile: path} when is_binary(url) <- Bootstrap.worker_gateway!(),
         {:ok, pem} <- File.read(path) do
      %{controller_url: url, ca_pem: pem}
    else
      _none -> nil
    end
  rescue
    # A gateway setting Ryker cannot use already keeps the gateway from starting.
    ArgumentError -> nil
  end

  @doc """
  A token that lets worker `worker_id` join install `install` once, within fifteen minutes:
  `{:ok, %{token, worker_id, workspace_ref, expires_at}}`, or `{:error, reason}` for a name
  workers cannot have or a revoked worker.
  """
  @spec worker_token(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def worker_token(worker_id, install, actor_ref),
    do: Enrollment.issue_token(worker_id, install, actor_ref)

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
