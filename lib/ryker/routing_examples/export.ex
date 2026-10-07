defmodule Ryker.RoutingExamples.Export do
  @moduledoc """
  The routing examples kept for training as JSON Lines: one object per line,
  oldest decision first, forgotten ones left out.

  Each object is a chat fine-tuning example. `messages` holds the exact
  prompt routing sent as the user turn and the model's answer as the
  assistant turn; `rejected_answers` the answers routing refused before that
  one, oldest first, each with the code of why and the correction the model
  was sent, for preference training; `output_schema` is the JSON Schema the
  answer had to follow; `labels` says which request it was, where, which
  model answered, what it decided, what happened next, what it cost, and the
  feedback people gave on the request:

      {"messages":[{"role":"user","content":"..."},{"role":"assistant","content":"..."}],
       "rejected_answers":[{"answer":"...","reason":"rejected:unknown_candidate","correction":"..."}],
       "output_schema":{...},
       "labels":{"example_id":"...","request_id":"...","request_ref":"...","input_id":"...",
                 "decided_at":"...","settled_at":"...","transport":"slack",
                 "conversation_ref":"...","thread_ref":"...","repository_ref":null,
                 "execution_mode":"live","model":"codex:gpt-5.6-luna/low@default",
                 "policy":"ryker-admission","decision":{...},"outcome":{...},"usage":{...},
                 "feedback":[{"kind":"reaction_added","value":"+1","category":"satisfied",
                              "occurred_at":"..."}]}}

  `request_id` is the request (episode) the decision started or joined; it
  is null when routing answered by itself. `feedback` is every signal about
  that request, or about routing's own answer, oldest first, copied beside
  the example as it arrived, so it outlives the feedback table's shorter
  window (`Ryker.RoutingExamples.copy_feedback/0`).

  The rows are read in batches inside one transaction and each line is handed
  on as it is encoded, so an export never holds the whole set in memory.
  """

  alias Ryker.RoutingExamples.{Example, Feedback}
  alias Ryker.TrainingExamples

  @batch 100

  @doc """
  Reduces every kept example's line through `fun`, as `Enum.reduce_while/3`
  does, and returns the last accumulator.
  """
  @spec reduce(acc, (iodata(), acc -> {:cont, acc} | {:halt, acc})) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  def reduce(acc, fun) when is_function(fun, 2) do
    Example.Query.kept()
    |> Example.Query.ordered_by_decided_at()
    |> TrainingExamples.reduce(@batch, feedback_order(), &line/1, acc, fun)
  end

  # One example as one line of JSON, newline included.
  defp line(%Example{forgotten_at: nil} = example),
    do: [Jason.encode_to_iodata!(document(example)), ?\n]

  defp feedback_order, do: Feedback.Query.ordered_by_occurred_at(Feedback.Query.all())

  defp document(example) do
    Jason.OrderedObject.new([
      {"messages",
       [
         Jason.OrderedObject.new([{"role", "user"}, {"content", example.prompt}]),
         Jason.OrderedObject.new([{"role", "assistant"}, {"content", example.answer}])
       ]},
      {"rejected_answers", example.rejected_answers},
      {"output_schema", example.output_schema},
      {"labels",
       Jason.OrderedObject.new([
         {"example_id", example.id},
         {"request_id", example.episode_id},
         {"request_ref", example.episode_ref},
         {"input_id", example.input_id},
         {"decided_at", DateTime.to_iso8601(example.decided_at)},
         {"settled_at", DateTime.to_iso8601(example.inserted_at)},
         {"transport", example.transport},
         {"conversation_ref", example.conversation_ref},
         {"thread_ref", example.thread_ref},
         {"repository_ref", example.repository_ref},
         {"execution_mode", Atom.to_string(example.execution_mode)},
         {"model", example.execution_target},
         {"policy", example.policy},
         {"decision", example.decision},
         {"outcome", example.outcome},
         {"usage", example.usage},
         {"feedback", Enum.map(example.feedback, &TrainingExamples.signal/1)}
       ])}
    ])
  end
end
