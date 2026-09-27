defmodule Ryker.RoutingExamples.Export do
  @moduledoc """
  The routing examples kept for training as JSON Lines: one object per line,
  oldest decision first, forgotten ones left out.

  Each object is a chat fine-tuning example. `messages` holds the exact
  prompt routing sent as the user turn and the model's answer as the
  assistant turn; `output_schema` is the JSON Schema the answer had to
  follow; `labels` says which request it was, where, which model answered,
  what it decided, what happened next and what it cost:

      {"messages":[{"role":"user","content":"..."},{"role":"assistant","content":"..."}],
       "output_schema":{...},
       "labels":{"example_id":"...","request_id":"...","request_ref":"...","input_id":"...",
                 "decided_at":"...","settled_at":"...","transport":"slack",
                 "conversation_ref":"...","thread_ref":"...","repository_ref":null,
                 "execution_mode":"live","model":"codex:gpt-5.6-luna/low@default",
                 "policy":"ryker-admission","decision":{...},"outcome":{...},"usage":{...}}}

  `request_id` is the request (episode) the decision started or joined, the
  key feedback about a request is kept under, so a training set can join it;
  it is null when routing answered by itself.

  The rows are read in batches inside one transaction and each line is handed
  on as it is encoded, so an export never holds the whole set in memory.
  """

  import Ecto.Query

  alias Ryker.Repo
  alias Ryker.RoutingExamples.Example

  @batch 100

  @doc """
  Reduces every kept example's line through `fun`, as `Enum.reduce_while/3`
  does, and returns the last accumulator.
  """
  @spec reduce(acc, (iodata(), acc -> {:cont, acc} | {:halt, acc})) ::
          {:ok, acc} | {:error, term()}
        when acc: term()
  def reduce(acc, fun) when is_function(fun, 2) do
    Repo.transaction(
      fn ->
        from(example in Example,
          where: is_nil(example.forgotten_at),
          order_by: [asc: example.decided_at, asc: example.id]
        )
        |> Repo.stream(max_rows: @batch)
        |> Stream.map(&line/1)
        |> Enum.reduce_while(acc, fun)
      end,
      timeout: :infinity
    )
  end

  @doc "One example as one line of JSON, newline included."
  @spec line(Example.t()) :: iodata()
  def line(%Example{forgotten_at: nil} = example),
    do: [Jason.encode_to_iodata!(document(example)), ?\n]

  defp document(example) do
    Jason.OrderedObject.new([
      {"messages",
       [
         Jason.OrderedObject.new([{"role", "user"}, {"content", example.prompt}]),
         Jason.OrderedObject.new([{"role", "assistant"}, {"content", example.answer}])
       ]},
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
         {"usage", example.usage}
       ])}
    ])
  end
end
