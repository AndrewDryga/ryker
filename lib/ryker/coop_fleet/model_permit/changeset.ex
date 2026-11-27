defmodule Ryker.CoopFleet.ModelPermit.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.CoopFleet.ModelPermit

  @reserve ~w(id run_id bucket_id job_ref provider account account_epoch owner_boot owner_pid deadline kind)a
  def reserve(attributes) do
    %ModelPermit{state: :reserved}
    |> cast(attributes, @reserve)
    |> validate_required(@reserve)
    |> foreign_key_constraint(:run_id)
    |> foreign_key_constraint(:bucket_id)
    |> check_constraint(:state, name: :coop_model_permit_valid)
  end

  def bind(permit, pid), do: change(permit, lease_pid: pid)
  def activate(permit, pid), do: change(permit, upstream_pid: pid, state: :active)
  def response(permit, id), do: change(permit, response_id: id)

  def finish(permit, reason, now),
    do: change(permit, state: :released, finished_at: now, finish_reason: reason)

  def uncertain(permit), do: change(permit, state: :uncertain)
end
