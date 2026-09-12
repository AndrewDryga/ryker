defmodule Mix.Tasks.Responder.BackfillLearningUsage do
  @moduledoc """
  Meters the learning executions that ran before the ledger recorded them, once.

      MIX_ENV=prod mix responder.backfill_learning_usage
      MIX_ENV=prod mix responder.backfill_learning_usage --apply

  Learning turns began writing `execution_usage` rows on 2026-09-11; the runs
  that finished earlier have no row, so `/usage` under-reports the memory lane.
  This command re-reads each of those turns from Coop and records it through the
  same accounting path the learning executor uses.

  Without `--apply` this is a read-only dry run: it reads Coop, prints the runs
  it can recover and the tokens they carry, and writes nothing. `--apply` writes
  them. Rerunning `--apply` recovers nothing further — a run the ledger already
  holds is not selected — so an interrupted reconciliation is resumed by running
  it again.

  Nothing is estimated. A run whose Coop session or turn is gone is reported as
  skipped with its stable reason, and so is a turn Coop kept without usage: a
  failed learning turn reports no counters, and a row of zeroes would read as a
  free execution.
  """

  use Mix.Task

  alias Mix.Tasks.Responder.OperatorSupport, as: Support
  alias Responder.Learning.{Runtime, UsageBackfill}

  @shortdoc "Dry-runs, or with --apply performs, the one-off learning usage backfill"

  @impl Mix.Task
  def run(arguments) do
    case Support.parse(arguments, [apply: :boolean], 0) do
      {:ok, options, []} -> print_result(backfill(options))
      {:error, reason} -> Support.fail("learning usage backfill", reason)
    end
  end

  defp backfill(options) do
    Support.with_configuration(fn _configuration ->
      with {:ok, settings} <- Runtime.configured_options(),
           do: UsageBackfill.reconcile(settings, mode(options))
    end)
  end

  defp mode(options),
    do: if(Keyword.get(options, :apply, false), do: :apply, else: :dry_run)

  defp print_result({:ok, report}), do: Support.print(report)
  defp print_result({:error, reason}), do: Support.fail("learning usage backfill", reason)
end
