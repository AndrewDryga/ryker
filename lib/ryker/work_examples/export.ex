defmodule Ryker.WorkExamples.Export do
  @moduledoc """
  The work examples kept for training as JSON Lines: one object per line,
  oldest settled turn first, forgotten ones left out.

  Each object is a chat fine-tuning example, as a routing example's is
  (`Ryker.RoutingExamples.Export`): `messages` holds the exact prompt the
  worker was sent as the user turn and the result Ryker accepted as the
  assistant turn. `trajectory` is what the worker did in between, in order,
  as Ryker recorded it (each event's kind, time and redacted payload: a tool
  call's input and output, a progress note's text), left in that shape for
  whoever trains to map onto their own tool-call format; `rejected_results`
  the results Ryker refused before, oldest first, each with the violations it
  named, for preference training; `context` and `output_schema` what was sent
  beside the prompt; `labels` which request it was, where, which model did
  it, what happened next, what it cost, and the feedback people gave:

      {"messages":[{"role":"user","content":"..."},{"role":"assistant","content":"..."}],
       "trajectory":[{"kind":"tool.completed","at":"...","payload":{...}}],
       "rejected_results":[{"result":"...","violations":["..."]}],
       "context":{...},"output_schema":{...},
       "labels":{"example_id":"...","request_id":"...","request_ref":"...","turn_id":"...",
                 "settled_at":"...","copied_at":"...","transport":"slack",
                 "conversation_ref":"...","thread_ref":"...","repository_ref":"...",
                 "execution_mode":"live","model":"codex:gpt-5.6-terra/high@oncall",
                 "outcome":{...},"usage":{...},
                 "feedback":[{"kind":"reaction_added","value":"+1","category":"satisfied",
                              "occurred_at":"..."}]}}

  The rows are read in batches inside one transaction and each line is handed
  on as it is encoded, so an export never holds the whole set in memory.
  """
  alias Ryker.Repo
  alias Ryker.Settings.Retention
  alias Ryker.TrainingExamples
  alias Ryker.WorkExamples.{Example, Feedback}

  # A work example's briefing is about fifty times a routing prompt.
  @batch 10

  @doc """
  Reduces every kept example's line through `fun`, as `Enum.reduce_while/3`
  does, and returns the last accumulator.
  """
  @spec reduce(acc, (iodata(), acc -> {:cont, acc} | {:halt, acc})) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  def reduce(acc, fun) when is_function(fun, 2) do
    examples = Example.Query.ordered_by_settled_at(Example.Query.kept())
    TrainingExamples.reduce(&kept?/0, examples, @batch, feedback_order(), &line/1, acc, fun)
  end

  defp kept?, do: Repo.one(Retention.Query.select_work_examples_enabled()) == true

  # One example as one line of JSON, newline included.
  defp line(%Example{forgotten_at: nil} = example),
    do: [Jason.encode_to_iodata!(document(example)), ?\n]

  defp feedback_order, do: Feedback.Query.ordered_by_occurred_at(Feedback.Query.all())

  defp document(example) do
    Jason.OrderedObject.new([
      {"messages",
       [
         Jason.OrderedObject.new([{"role", "user"}, {"content", example.briefing}]),
         Jason.OrderedObject.new([{"role", "assistant"}, {"content", example.result}])
       ]},
      {"trajectory", example.trajectory},
      {"rejected_results", example.rejected_results},
      {"context", example.context},
      {"output_schema", example.output_schema},
      {"labels",
       Jason.OrderedObject.new([
         {"example_id", example.id},
         {"request_id", example.episode_id},
         {"request_ref", example.episode_ref},
         {"turn_id", example.turn_id},
         {"settled_at", DateTime.to_iso8601(example.settled_at)},
         {"copied_at", DateTime.to_iso8601(example.inserted_at)},
         {"transport", example.transport},
         {"conversation_ref", example.conversation_ref},
         {"thread_ref", example.thread_ref},
         {"repository_ref", example.repository_ref},
         {"execution_mode", Atom.to_string(example.execution_mode)},
         {"model", example.execution_target},
         {"outcome", example.outcome},
         {"usage", example.usage},
         {"feedback", Enum.map(example.feedback, &TrainingExamples.signal/1)}
       ])}
    ])
  end
end
