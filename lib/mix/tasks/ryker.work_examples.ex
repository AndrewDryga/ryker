defmodule Mix.Tasks.Ryker.WorkExamples do
  @moduledoc """
  Exports the work examples kept for training as JSON Lines, one example per
  line (`Ryker.WorkExamples.Export`), the file the Data retention page
  downloads.

      mix ryker.work_examples --output work-examples.jsonl

  Without `--output` the lines are written to standard output.
  """

  use Mix.Task
  alias Mix.Tasks.Ryker.OperatorSupport, as: Support
  alias Ryker.WorkExamples.Export

  @shortdoc "Exports the work examples kept for training as JSON Lines"

  @impl Mix.Task
  def run(arguments), do: Support.export_lines(arguments, "work example", &Export.reduce/2)
end
