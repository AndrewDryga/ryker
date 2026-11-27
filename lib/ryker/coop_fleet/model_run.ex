defmodule Ryker.CoopFleet.ModelRun do
  @moduledoc false
  use Ryker, :schema

  schema "coop_model_runs" do
    belongs_to(:session, Ryker.Work.Session)
    belongs_to(:placement, Ryker.CoopFleet.Placement)
    field(:worker_id, :string)
    field(:worker_epoch, Ecto.UUID)
    field(:run_id, :string)
    field(:job_digest, :string)
    field(:provider, :string)
    field(:account, :string)
    field(:epoch, :integer)
    field(:token_hash, :string)
    field(:expires_at, :utc_datetime_usec)
    timestamps()
  end
end
