defmodule Ryker.Operator.FailureDismissal do
  @moduledoc "One failure a person left as it is: its identity and how it failed then."
  use Ecto.Schema

  @primary_key false
  schema "failure_dismissals" do
    field(:kind, :string, primary_key: true)
    field(:ref, :string, primary_key: true)
    field(:failure_summary, :string)
    field(:left_by, :string)
    field(:left_at, :utc_datetime_usec)
  end
end
