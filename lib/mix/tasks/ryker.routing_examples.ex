defmodule Mix.Tasks.Ryker.RoutingExamples do
  @shortdoc "Exports the routing examples kept for training as JSON Lines"
  @moduledoc """
  Exports the routing examples kept for training as JSON Lines, one example
  per line (`Ryker.RoutingExamples.Export`), the file the Data retention page
  downloads.

      mix ryker.routing_examples --output routing-examples.jsonl

  Without `--output` the lines are written to standard output.
  """
  use Mix.Task
  alias Mix.Tasks.Ryker.OperatorSupport, as: Support
  alias Ryker.RoutingExamples.Export

  @impl Mix.Task
  def run(arguments), do: Support.export_lines(arguments, "routing example", &Export.reduce/2)
end
