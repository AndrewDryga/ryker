defmodule Ryker.CoopFleet.ModelPermit do
  @moduledoc false
  use Ryker, :schema

  schema "coop_model_permits" do
    belongs_to(:run, Ryker.CoopFleet.ModelRun)
    belongs_to(:bucket, Ryker.CoopFleet.ModelBucket, type: :string)
    field(:job_ref, :string)
    field(:provider, :string)
    field(:account, :string)
    field(:account_epoch, :integer)
    field(:owner_boot, Ecto.UUID)
    field(:owner_pid, :string)
    field(:lease_pid, :string)
    field(:upstream_pid, :string)
    field(:kind, Ecto.Enum, values: [:http, :websocket])
    field(:response_id, :string)
    field(:state, Ecto.Enum, values: [:reserved, :active, :released, :uncertain])
    field(:deadline, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    field(:finish_reason, :string)
    timestamps()
  end
end
