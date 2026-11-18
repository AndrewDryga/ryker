defmodule Ryker.GitHub.CIRepair.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.GitHub.CIRepair

  @identity ~w(identity binding_ref repository_ref repository_id installation_id number)a
  @mutable ~w(revision generation rounds failure_open pending_heads refresh_requested current_round_id allowed last_attempt_head status observation external_receipt rendered_fingerprint next_attempt_at attempt_count lease_ref lease_expires_at last_error)a

  def insert(attributes) do
    %CIRepair{}
    |> cast(attributes, @identity ++ [:next_attempt_at])
    |> validate_required(@identity)
    |> repair_constraints()
  end

  def update(%CIRepair{} = repair, attributes),
    do: repair |> cast(attributes, @mutable) |> repair_constraints()

  defp repair_constraints(changeset) do
    changeset
    |> unique_constraint(:identity)
    |> check_constraint(:identity, name: :github_ci_repair_valid)
    |> foreign_key_constraint(:current_round_id, name: :github_ci_repair_round_owned)
  end
end
