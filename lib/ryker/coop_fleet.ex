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

  @doc "Save controller-owned access for a configured provider account."
  defdelegate put_model_key(reference, secret, actor),
    to: Ryker.CoopFleet.ModelAccounts,
    as: :put_key

  defdelegate model_receive_code(account, actor),
    to: Ryker.CoopFleet.ModelTransfer,
    as: :receive_code

  defdelegate receive_model_account(account, target, bundle, actor),
    to: Ryker.CoopFleet.ModelTransfer,
    as: :receive_bundle

  @doc "Remove provider access and invalidate its outstanding run grants."
  defdelegate remove_model_account(reference, actor),
    to: Ryker.CoopFleet.ModelAccounts,
    as: :remove_account

  @doc "Controller account access states, with no provider credentials or network refresh."
  defdelegate model_account_statuses(workspace_ref \\ nil),
    to: Ryker.CoopFleet.ModelAccounts,
    as: :statuses

  @doc "Controller inference capacity shared by aliases of one provider principal."
  defdelegate model_capacity(reference), to: Ryker.CoopFleet.ModelPermits, as: :capacity

  @doc "Set concurrent provider requests; lowering a limit does not interrupt admitted work."
  defdelegate set_model_concurrency(reference, count, actor),
    to: Ryker.CoopFleet.ModelPermits,
    as: :set_limit

  @doc "Held inference requests, including unresolved prior controller generations."
  defdelegate held_model_requests(), to: Ryker.CoopFleet.ModelPermits, as: :held_requests

  @doc "Release a prior controller's hold after the operator verifies that controller stopped."
  defdelegate confirm_model_controller_stopped(id, boot, actor),
    to: Ryker.CoopFleet.ModelPermits,
    as: :acknowledge_stopped

  @doc "Approved model presets available to the installation's selected accounts."
  defdelegate model_presets(work), to: PresetCatalog, as: :choices

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
  Whether an enrolled worker accepts a model in its provider's fast mode (a +fast target):
  a job asking for it is placed only on such a worker, so until one advertises it, Settings ›
  Models offers no Fast box.
  """
  @spec fast_mode_available?() :: boolean()
  def fast_mode_available? do
    Worker.Query.enrolled()
    |> Repo.all()
    |> Enum.any?(&Worker.advertises?(&1, "fast-target", "1"))
  end

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
