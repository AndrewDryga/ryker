defmodule Mix.Tasks.Ryker.WorkExamples do
  @shortdoc "Exports the work examples kept for training as JSON Lines"
  @moduledoc """
  Exports the work examples kept for training as JSON Lines, one example per
  line (`Ryker.WorkExamples.Export`), the file the Data retention page
  downloads.

      mix ryker.work_examples --output work-examples.jsonl

  Without `--output` the lines are written to standard output.
  """
  use Mix.Task
  alias Mix.Tasks.Ryker.OperatorSupport, as: Support
  alias Ryker.WorkExamples

  @impl Mix.Task
  def run(arguments),
    do: Support.export_lines(arguments, "work example", &WorkExamples.Export.reduce/2)
end
