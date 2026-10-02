defmodule Ryker.WorkExamples.Feedback do
  @moduledoc """
  One signal of feedback about a work example's request, copied beside the
  example (`Ryker.WorkExamples.copy_feedback/0`) so it lasts as long as the
  example does: `answer_feedback` itself expires at the operational horizon.

  As for routing examples (`Ryker.RoutingExamples.Feedback`), it holds the
  kind, value, category and time of the signal and names the signal it copied
  without a foreign key; never who gave it or a note's words.
  """
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "work_example_feedback" do
    field(:example_id, :binary_id)
    field(:signal_id, :binary_id)
    field(:kind, :string)
    field(:value, :string)
    field(:category, :string)
    field(:occurred_at, :utc_datetime_usec)
    field(:inserted_at, :utc_datetime_usec, read_after_writes: true)
  end

  @type t :: %__MODULE__{}
end
