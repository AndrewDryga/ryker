defmodule Ryker.RoutingExamples.Feedback do
  @moduledoc """
  One signal of feedback about a routing example's request, copied beside the
  example (`Ryker.RoutingExamples.copy_feedback/0`) so it lasts as long as
  the example does: `answer_feedback` itself expires at the operational
  horizon, and an example is kept for its own, longer window.

  It holds what kind of signal it was, its value (an emoji, a feeling or a
  rating), its category and when it happened (`Ryker.Feedback.Signal`), and
  names the signal it copied (`signal_id`) without a foreign key. Who gave
  it and the words of a note are left out: a training label needs neither,
  and a note can quote a message the example's forgetting cannot trace.
  """
  use Ryker, :schema

  schema "routing_example_feedback" do
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
