defmodule Ryker.ControlPlane.RunningSystemProjection do
  @moduledoc """
  What the running-system card at the bottom of Settings › Advanced reads
  (`Ryker.ControlPlane.RunningSystem`): the Ryker version, every worker with
  its storage report, whether tasks that change code can run here, and the
  database clock the card measures a worker's last contact against.
  """
  alias Ryker.CoopFleet
  alias Ryker.Repo
  alias Ryker.Work

  @doc "What the card shows, read afresh."
  @spec fetch() :: map()
  def fetch do
    %{
      version: to_string(Application.spec(:ryker, :vsn) || "unknown"),
      workers:
        CoopFleet.Worker.Query.all() |> CoopFleet.Worker.Query.ordered_by_id() |> Repo.all(),
      supported: Work.CodeEditingSetup.checkpoint_supported?(),
      now: Repo.now!()
    }
  end
end
