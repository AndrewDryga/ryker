defmodule Ryker.ControlPlane.RunningSystemProjection do
  @moduledoc """
  What the running-system card at the bottom of Settings › Advanced reads
  (`Ryker.ControlPlane.RunningSystem`): the Ryker version, every worker with
  its storage report, whether tasks that change code can run here, and the
  database clock the card measures a worker's last contact against.
  """
  alias Ryker.CoopFleet.Worker
  alias Ryker.Repo
  alias Ryker.Work.CodeEditingSetup

  @doc "What the card shows, read afresh."
  @spec fetch() :: map()
  def fetch do
    %{
      version: to_string(Application.spec(:ryker, :vsn) || "unknown"),
      workers: Worker.Query.all() |> Worker.Query.ordered_by_id() |> Repo.all(),
      supported: CodeEditingSetup.checkpoint_supported?(),
      now: Repo.now!()
    }
  end
end
