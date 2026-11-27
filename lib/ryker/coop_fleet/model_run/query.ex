defmodule Ryker.CoopFleet.ModelRun.Query do
  @moduledoc false
  use Ryker, :query
  alias Ryker.CoopFleet.ModelRun

  def all, do: from(run in ModelRun, as: :model_run)

  def identity(placement, run_id, provider, account, epoch, worker_epoch) do
    from(run in all(),
      where:
        run.placement_id == ^placement and run.run_id == ^run_id and
          run.provider == ^provider and run.account == ^account and run.epoch == ^epoch and
          run.worker_epoch == ^worker_epoch
    )
  end

  def token(hash), do: from(run in all(), where: run.token_hash == ^hash)
end
