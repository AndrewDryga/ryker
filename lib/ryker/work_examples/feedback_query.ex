defmodule Ryker.WorkExamples.FeedbackQuery do
  @moduledoc "Feedback kept with Work examples, for every read of `work_example_feedback`."
  import Ecto.Query
  alias Ryker.Feedback.Signal
  alias Ryker.WorkExamples.{Example, Feedback}

  def all, do: from(feedback in Feedback, as: :work_example_feedback)

  @doc "The feedback on the examples `examples` selects."
  def for_examples(queryable \\ all(), examples) do
    ids = from(example in examples, select: example.id)
    where(queryable, [work_example_feedback: f], f.example_id in subquery(ids))
  end

  def oldest_first(queryable),
    do: order_by(queryable, [work_example_feedback: f], asc: f.occurred_at, asc: f.id)

  @doc "A copy of each feedback signal on a kept example's request, as rows of `work_example_feedback`."
  def copies_of_signals do
    from(signal in Signal,
      join: example in Example,
      on:
        is_nil(example.forgotten_at) and not is_nil(signal.episode_id) and
          signal.episode_id == example.episode_id,
      select: %{
        id: fragment("gen_random_uuid()"),
        example_id: example.id,
        signal_id: signal.id,
        kind: type(signal.kind, :string),
        value: fragment("NULLIF(left(?, 256), '')", signal.value),
        category: type(signal.category, :string),
        occurred_at: signal.occurred_at
      }
    )
  end
end
