defmodule Mix.Tasks.Ryker.Failures do
  @shortdoc "Lists typed retryable durable failures"
  @moduledoc """
  Lists bounded retryable failure context as JSON.

      MIX_ENV=prod mix ryker.failures
  """
  use Mix.Task
  alias Mix.Tasks.Ryker.OperatorSupport, as: Support
  alias Ryker.Operator

  @impl Mix.Task
  def run(arguments) do
    case Support.parse(arguments, [], 0) do
      {:ok, [], []} -> print_result(Support.with_repo(&Operator.Failures.list/0))
      {:error, reason} -> Support.fail("operator failures", reason)
    end
  end

  defp print_result({:ok, failures}), do: Support.print(failures)
  defp print_result({:error, reason}), do: Support.fail("operator failures", reason)
end
