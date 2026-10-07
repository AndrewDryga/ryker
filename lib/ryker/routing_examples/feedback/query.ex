defmodule Ryker.RoutingExamples.Feedback.Query do
  @moduledoc "Feedback kept with routing examples, for every read of `routing_example_feedback`."
  import Ecto.Query
  alias Ryker.Delivery.RoutingResponse
  alias Ryker.Feedback.Signal
  alias Ryker.RoutingExamples.{Example, Feedback}

  def all, do: from(feedback in Feedback, as: :routing_example_feedback)

  @doc "The feedback on the examples `examples` selects."
  def by_examples(queryable \\ all(), examples) do
    ids = from(example in examples, select: example.id)
    where(queryable, [routing_example_feedback: f], f.example_id in subquery(ids))
  end

  def ordered_by_occurred_at(queryable),
    do: order_by(queryable, [routing_example_feedback: f], asc: f.occurred_at, asc: f.id)

  @doc """
  A copy of each feedback signal on a kept example's request or message, as
  rows of `routing_example_feedback`. A reaction names the message it is on,
  and goes only with the decision that sent it, a reply routing sent by
  itself: one on any message of a request labelled every routing decision of
  it (2026-10-04 review).
  """
  def copies_of_signals do
    from(signal in Signal,
      as: :answer_feedback,
      join: example in Example,
      as: :routing_examples,
      on:
        is_nil(example.forgotten_at) and
          ((not is_nil(signal.episode_id) and signal.episode_id == example.episode_id) or
             (not is_nil(signal.input_id) and signal.input_id == example.input_id)),
      where: is_nil(signal.message_ref) or exists(sent_by_example_decision()),
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

  # Routing sent the message the signal names for the example's decision.
  defp sent_by_example_decision do
    from(response in RoutingResponse,
      where:
        response.input_id == parent_as(:routing_examples).input_id and
          fragment("(?::jsonb)->>'message_ref'", response.external_receipt) ==
            parent_as(:answer_feedback).message_ref,
      select: 1
    )
  end
end
