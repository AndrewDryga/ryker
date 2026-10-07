defmodule Ryker.Evals.ImprovementReplay do
  @moduledoc """
  Asks recorded self-analyses again under today's instructions and contract
  (`Ryker.Evals.ImprovementReplayCase`), and says how many put the fault in the same place.

  The runs are read from a JSON Lines file of analysis runs, one `{"run_id", "prompt",
  "result"}` object per line, as `docs/testing.md` exports them from the database. A prompt
  holds what people said, so the file and the report stay outside the repository, and the
  report names each run and its diagnosis, nothing of what was said.

  A replay compares with the recorded diagnosis, not with a right answer: it finds what a
  change to the instructions moves. Whether a move is better is for a person to read, with the
  request's own page open.
  """

  alias Ryker.Evals.{CoopRunner, ImprovementReplayCase, JsonLines}

  @doc "The cases in an export file, oldest first, and the lines that could not be read with why."
  @spec cases(String.t()) :: {:ok, [ImprovementReplayCase.t()], [map()]} | {:error, term()}
  def cases(path) when is_binary(path) do
    case JsonLines.read(path, &ImprovementReplayCase.new/1) do
      {:ok, _cases, _skipped} = read -> read
      {:error, :not_found} -> {:error, {:improvement_runs_not_found, path}}
    end
  end

  @doc "Runs the cases on the eval worker (`Ryker.Evals.CoopRunner`)."
  @spec run([ImprovementReplayCase.t()], keyword()) :: {:ok, map()} | {:error, term()}
  def run(cases, options), do: CoopRunner.run(cases, options)

  @doc "How many diagnoses stayed the same, and each run whose diagnosis moved or went unanswered."
  @spec summary([ImprovementReplayCase.t()], map(), [map()]) :: map()
  def summary(cases, %{results: results}, skipped) do
    by_id = Map.new(results, &{&1.eval_id, &1})

    rows =
      Enum.map(cases, fn replay ->
        result = Map.get(by_id, replay.eval_id, %{status: :failed, reason: :not_run})
        row(replay, result)
      end)

    %{
      total: length(cases),
      same: Enum.count(rows, &(&1.status == :same)),
      changed: Enum.count(rows, &(&1.status == :changed)),
      not_answered: Enum.count(rows, &(&1.status == :not_answered)),
      skipped: skipped,
      runs: rows
    }
  end

  defp row(replay, %{status: :passed, decision: replayed}),
    do: %{eval_id: replay.eval_id, status: :same, recorded: replay.recorded, replayed: replayed}

  defp row(replay, %{status: :failed, decision: replayed}) when is_map(replayed),
    do: %{
      eval_id: replay.eval_id,
      status: :changed,
      recorded: replay.recorded,
      replayed: replayed
    }

  defp row(replay, result),
    do: %{
      eval_id: replay.eval_id,
      status: :not_answered,
      recorded: replay.recorded,
      reason: inspect(result[:reason])
    }
end
