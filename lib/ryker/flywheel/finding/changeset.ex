defmodule Ryker.Flywheel.Finding.Changeset do
  @moduledoc "Validates a proposal and its recorded lifecycle changes."
  use Ryker, :changeset
  alias Ryker.Flywheel.Finding

  @fields [:key, :run_id, :owner, :kind, :proposal, :evidence]
  @transitions [
    :status,
    :history,
    :task_id,
    :revisit_at,
    :deployed_version,
    :shipped_at,
    :outcome,
    :owner,
    :kind,
    :proposal,
    :evidence
  ]

  def insert(attributes) do
    %Finding{}
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> validate_format(:key, ~r/^[a-z0-9][a-z0-9-]{0,119}$/)
    |> unique_constraint(:key)
    |> foreign_key_constraint(:run_id)
    |> check_constraint(:status, name: :flywheel_finding_valid)
  end

  def transition(%Finding{} = finding, attributes),
    do: cast(finding, attributes, @transitions) |> unique_constraint(:task_id)

  def observe(%Finding{} = finding, evidence), do: change(finding, evidence: evidence)
end
