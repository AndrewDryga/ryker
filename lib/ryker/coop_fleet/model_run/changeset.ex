defmodule Ryker.CoopFleet.ModelRun.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.CoopFleet.ModelRun

  @fields ~w(id session_id placement_id worker_id worker_epoch run_id job_digest provider account epoch token_hash expires_at)a

  def insert(attributes, now) do
    %ModelRun{inserted_at: now, updated_at: now}
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> unique_constraint([:placement_id, :run_id, :provider, :account, :epoch, :worker_epoch],
      name: :coop_model_runs_run_identity
    )
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:placement_id)
    |> foreign_key_constraint(:session_id)
  end

  def renew(run, expires, now),
    do: change(run, expires_at: expires, updated_at: now)
end
