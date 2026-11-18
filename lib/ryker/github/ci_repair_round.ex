defmodule Ryker.GitHub.CIRepairRound do
  @moduledoc "One immutable automatic repair request and its eventual saved outcome."
  use Ryker, :schema

  schema "github_ci_repair_rounds" do
    belongs_to(:repair, Ryker.GitHub.CIRepair)
    field(:generation, :integer)
    field(:ordinal, :integer)
    field(:entry_id, :binary_id)
    field(:head, :string)
    field(:snapshot, Ryker.CanonicalJSON.Type)
    field(:outcome, Ryker.CanonicalJSON.Type)
    field(:finished_at, :utc_datetime_usec)
    field(:inserted_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
