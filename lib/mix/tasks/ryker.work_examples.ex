defmodule Mix.Tasks.Ryker.WorkExamples do
  @moduledoc """
  Exports the work examples kept for training as JSON Lines, one example per
  line (`Ryker.WorkExamples.Export`), the file the Data retention page
  downloads.

      MIX_ENV=prod mix ryker.work_examples --output work-examples.jsonl

  Without `--output` the lines are written to standard output.
  """

  use Mix.Task

  alias Mix.Tasks.Ryker.OperatorSupport, as: Support
  alias Ryker.WorkExamples.Export

  @shortdoc "Exports the work examples kept for training as JSON Lines"

  @impl Mix.Task
  def run(arguments) do
    case Support.parse(arguments, [output: :string], 0) do
      {:ok, options, []} -> export(Keyword.get(options, :output))
      {:error, reason} -> Support.fail("work example export", reason)
    end
  end

  defp export(nil) do
    case Support.with_repo(fn -> write(:stdio) end) do
      {:ok, _count} -> :ok
      {:error, reason} -> Support.fail("work example export", reason)
    end
  end

  defp export(path) do
    result =
      File.open(path, [:write, :binary], fn device ->
        Support.with_repo(fn -> write(device) end)
      end)

    case result do
      {:ok, {:ok, count}} -> Mix.shell().info("Wrote #{count} work examples to #{path}")
      {:ok, {:error, reason}} -> Support.fail("work example export", reason)
      {:error, reason} -> Support.fail("work example export", {:output, reason})
    end
  end

  defp write(device) do
    Export.reduce(0, fn line, count ->
      IO.binwrite(device, line)
      {:cont, count + 1}
    end)
  end
end
