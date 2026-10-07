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
  alias Ryker.Evals.{CoopRunner, JsonLines, RoutingReplayCase}
  alias Ryker.LocalRouting.Client

  @doc """
  The cases in an export file, oldest first, at most `limit` of them, and the
  examples that could not be replayed with why.
  """
  @spec cases(String.t(), pos_integer() | nil) ::
          {:ok, [RoutingReplayCase.t()], [map()]} | {:error, term()}
  def cases(path, limit \\ nil) when is_binary(path) do
    case JsonLines.read(path, &RoutingReplayCase.new/1) do
      {:ok, cases, skipped} -> {:ok, if(limit, do: Enum.take(cases, limit), else: cases), skipped}
      {:error, :not_found} -> {:error, {:routing_examples_not_found, path}}
    end
  end

  @doc "Runs the cases on the eval worker (`Ryker.Evals.CoopRunner`)."
  @spec run([RoutingReplayCase.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def run(cases, options), do: CoopRunner.run(cases, options)

  @doc """
  Runs the cases on a local routing model, the way routing's local comparison
  asks it (`Ryker.LocalRouting.Client`): each case once, one at a time, with
  no repair, since a cascade acts on the first answer the local model gives.
  """
  @spec run_local([RoutingReplayCase.t()], map()) :: {:ok, map()}
  def run_local(cases, %{endpoint: _endpoint, model: _model, timeout_ms: _timeout} = options),
    do: {:ok, %{results: Enum.map(cases, &local_result(&1, options))}}

  defp local_result(replay, options) do
    case Client.ask(options, replay.prompt, replay.schema) do
      {:ok, %{content: content, ms: ms}} when is_binary(content) ->
        case RoutingReplayCase.validate(replay, content) do
          {:accept, %{document: document, passed: passed}} ->
            %{
              eval_id: replay.eval_id,
              status: if(passed, do: :passed, else: :failed),
              decision: document,
              ms: ms
            }

          {:reject, [why | _more]} ->
            %{eval_id: replay.eval_id, status: :failed, reason: {:refused_answer, why}, ms: ms}
        end

      {:ok, %{ms: ms}} ->
        %{eval_id: replay.eval_id, status: :failed, reason: :empty_answer, ms: ms}

      {:error, {_kind, why}} ->
        %{eval_id: replay.eval_id, status: :failed, reason: {:local_model, why}}
    end
  end

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
      by_action: by_action(rows),
      latency_ms: latency(results),
      examples: Enum.reject(rows, &(&1.status == :same))
    }
  end

  # For each action routing recorded: how many answers routing could act on,
  # how many made Ryker do the same, and what the others did instead. A cascade
  # trusts the local model only with actions it reliably keeps.
  defp by_action(rows) do
    rows
    |> Enum.group_by(& &1.recorded["action"])
    |> Map.new(fn {action, rows} ->
      changed = for %{status: :changed, replayed: %{"action" => to}} <- rows, do: to

      {action,
       %{
         total: length(rows),
         valid: Enum.count(rows, &(&1.status in [:same, :changed])),
         same: Enum.count(rows, &(&1.status == :same)),
         changed_to: Enum.frequencies(changed)
       }}
    end)
  end

  # How long each answer took, where the run measured it: a local model does.
  defp latency(results) do
    case results |> Enum.map(&Map.get(&1, :ms)) |> Enum.filter(&is_integer/1) |> Enum.sort() do
      [] ->
        nil

      times ->
        %{
          count: length(times),
          median: Enum.at(times, div(length(times), 2)),
          p90: Enum.at(times, min(length(times) - 1, div(length(times) * 9, 10)))
        }
    end
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
