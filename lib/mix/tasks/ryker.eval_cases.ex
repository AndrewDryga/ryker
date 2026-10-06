defmodule Mix.Tasks.Ryker.EvalCases do
  @moduledoc """
  Writes every request accepted as an eval case on Feedback › What to fix as
  a world scenario directory (`Ryker.Improvement.Export`), the same files the
  page downloads.

      MIX_ENV=prod mix ryker.eval_cases --output DIR

  Move the directories into `testdata/scenarios/`, fill in what each
  `PROVENANCE.md` lists, and run them with `make eval-world`.
  """

  use Mix.Task
  alias Mix.Tasks.Ryker.OperatorSupport, as: Support
  alias Ryker.Improvement.Export

  @shortdoc "Writes the accepted eval cases as world scenario directories"

  @impl Mix.Task
  def run(arguments) do
    with {:ok, options, []} <- Support.parse(arguments, [output: :string], 0),
         {:ok, directory} <- Support.required_option(options, :output),
         {:ok, count} <- Support.with_repo(fn -> Export.write(directory) end) do
      Mix.shell().info("Wrote #{count} eval cases to #{directory}")
    else
      {:error, reason} -> Support.fail("eval case export", reason)
    end
  end
end
