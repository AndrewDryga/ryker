defmodule Ryker.GitHub.CIRepairRound.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.GitHub.CIRepairRound

  @fields ~w(id repair_id generation ordinal entry_id head snapshot inserted_at)a
  def insert(attributes) do
    %CIRepairRound{}
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> unique_constraint([:repair_id, :generation, :ordinal])
    |> unique_constraint(:entry_id)
    |> check_constraint(:head, name: :github_ci_repair_round_valid)
  end

  def finish(%CIRepairRound{finished_at: nil} = round, outcome, now),
    do: change(round, outcome: outcome, finished_at: now)
end
