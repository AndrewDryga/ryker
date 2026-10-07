defmodule Ryker.WorkExamples.Feedback.Query do
  @moduledoc "Feedback kept with Work examples, for every read of `work_example_feedback`."
  use Ryker, :query
  alias Ryker.Delivery.PlatformAction
  alias Ryker.Feedback.Signal
  alias Ryker.Work.Turn
  alias Ryker.WorkExamples.{Example, Feedback}

  def all, do: from(feedback in Feedback, as: :work_example_feedback)

  @doc "The feedback on the examples `examples` selects."
  def by_examples(queryable \\ all(), examples) do
    ids = from(example in examples, select: example.id)
    where(queryable, [work_example_feedback: f], f.example_id in subquery(ids))
  end

  def ordered_by_occurred_at(queryable),
    do: order_by(queryable, [work_example_feedback: f], asc: f.occurred_at, asc: f.id)

  @doc """
  A copy of each feedback signal on a kept example's request, as rows of
  `work_example_feedback`. A reaction names the message it is on, and goes
  only with the turn that sent it, as its reply or an update: one on the
  third turn's reply labelled every turn of the request (2026-10-04 review).
  """
  def copies_of_signals do
    from(signal in Signal,
      as: :answer_feedback,
      join: example in Example,
      as: :work_examples,
      on:
        is_nil(example.forgotten_at) and not is_nil(signal.episode_id) and
          signal.episode_id == example.episode_id,
      where: is_nil(signal.message_ref) or exists(sent_by_example_turn()),
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

  # The example's turn delivered the message the signal names, as its reply
  # or as an update it posted.
  defp sent_by_example_turn do
    replies =
      from(turn in Turn,
        where:
          turn.id == parent_as(:work_examples).turn_id and
            fragment("(?::jsonb)->>'message_ref'", turn.external_receipt) ==
              parent_as(:answer_feedback).message_ref,
        select: 1
      )

    from(action in PlatformAction,
      where:
        action.turn_id == parent_as(:work_examples).turn_id and
          fragment("(?::jsonb)->>'message_ref'", action.external_receipt) ==
            parent_as(:answer_feedback).message_ref,
      select: 1,
      union_all: ^replies
    )
  end
end
