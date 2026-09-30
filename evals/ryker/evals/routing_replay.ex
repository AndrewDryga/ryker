defmodule Ryker.Evals.RoutingReplay do
  @moduledoc """
  Asks routing's recorded decisions again under today's prompt and contract
  (`Ryker.Evals.RoutingReplayCase`), and says how many it would make the same.

  The examples are the routing examples Ryker keeps for training, as the Data
  retention page downloads them or `mix ryker.routing_examples` writes them.
  They hold what people said, so they are read from wherever the operator
  keeps the file and never copied into the repository or the report: the
  report names each example and what was decided, nothing of what was said.

  A replay compares with the recorded decision, not with a right answer: it
  finds what a prompt change moves. Whether each move is better is for a
  person to read, with the request's own page open.
  """

  alias Ryker.Evals.{CoopRunner, RoutingReplayCase}

  @doc """
  The cases in an export file, oldest first, at most `limit` of them, and the
  examples that could not be replayed with why.
  """
  @spec cases(String.t(), pos_integer() | nil) ::
          {:ok, [RoutingReplayCase.t()], [map()]} | {:error, term()}
  def cases(path, limit \\ nil) when is_binary(path) do
    if File.regular?(path) do
      {cases, skipped} = read(path)
      {:ok, if(limit, do: Enum.take(cases, limit), else: cases), skipped}
    else
      {:error, {:routing_examples_not_found, path}}
    end
  end

  defp read(path) do
    {cases, skipped} =
      path
      |> File.stream!(:line)
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.with_index(1)
      |> Enum.map(fn {line, number} -> {number, replay(line)} end)
      |> Enum.split_with(&match?({_number, {:ok, _replay}}, &1))

    {Enum.map(cases, fn {_number, {:ok, replay}} -> replay end),
     Enum.map(skipped, fn {number, {:error, reason}} -> skipped(number, reason) end)}
  end

  defp replay(line) do
    case Jason.decode(line) do
      {:ok, document} -> RoutingReplayCase.new(document)
      {:error, _reason} -> {:error, :unreadable_line}
    end
  end

  defp skipped(line, reason), do: %{line: line, reason: inspect(reason)}

  @doc "Runs the cases on the eval worker (`Ryker.Evals.CoopRunner`)."
  @spec run([RoutingReplayCase.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def run(cases, options), do: CoopRunner.run(cases, options)

  @doc """
  How many decisions stayed the same, field by field, and each one that
  changed or could not be asked again, by its example.
  """
  @spec summary([RoutingReplayCase.t()], map(), [map()]) :: map()
  def summary(cases, %{results: results}, skipped) do
    by_id = Map.new(results, &{&1.eval_id, &1})

    rows =
      Enum.map(cases, fn replay ->
        result = Map.get(by_id, replay.eval_id, %{status: :failed, reason: :not_run})
        row(replay, result)
      end)

    answered = Enum.filter(rows, &(&1.status in [:same, :changed]))

    %{
      total: length(cases),
      same: Enum.count(rows, &(&1.status == :same)),
      changed: Enum.count(rows, &(&1.status == :changed)),
      not_answered: Enum.count(rows, &(&1.status == :not_answered)),
      skipped: skipped,
      fields:
        Map.new(~w(action episode_ref relation), fn field ->
          {field, Enum.count(answered, &(&1.recorded[field] == &1.replayed[field]))}
        end),
      sentiment: sentiment(cases, rows),
      examples: Enum.reject(rows, &(&1.status == :same))
    }
  end

  # Where routing was asked how the sender feels, how many answers said, and
  # each feeling they read.
  defp sentiment(cases, rows) do
    read =
      for {%{sentiment_offered: true}, %{replayed: %{"sentiment" => feeling}}} <-
            Enum.zip(cases, rows),
          do: feeling

    %{offered: Enum.count(cases, & &1.sentiment_offered), read: Enum.frequencies(read)}
  end

  defp row(replay, %{status: :passed, decision: replayed}),
    do: example(replay, :same, replayed)

  defp row(replay, %{status: :failed, decision: replayed}) when is_map(replayed),
    do: example(replay, :changed, replayed)

  defp row(replay, result) do
    replay
    |> example(:not_answered, nil)
    |> Map.put(:reason, inspect(Map.get(result, :reason)))
  end

  defp example(replay, status, replayed) do
    %{
      status: status,
      example_id: replay.labels["example_id"],
      request_ref: replay.labels["request_ref"],
      decided_at: replay.labels["decided_at"],
      recorded: replay.recorded,
      replayed: replayed
    }
  end
end
