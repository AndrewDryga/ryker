defmodule Mix.Tasks.Ryker.Status do
  @moduledoc """
  Prints one payload-free durable operator snapshot as JSON.

      MIX_ENV=prod mix ryker.status
  """

  use Mix.Task

  alias Mix.Tasks.Ryker.OperatorSupport, as: Support
  alias Ryker.Operator.Status

  @shortdoc "Prints unified durable Ryker status"

  @impl Mix.Task
  def run(arguments) do
    case Support.parse(arguments, [], 0) do
      {:ok, [], []} -> print_result(snapshot())
      {:error, reason} -> Support.fail("operator status", reason)
    end
  end

  defp snapshot do
    Support.with_configuration(fn configuration ->
      Status.snapshot(configuration: configuration, check_progress: false, check_runtimes: false)
    end)
  end

  defp print_result({:ok, snapshot}), do: Support.print(snapshot)
  defp print_result({:error, reason}), do: Support.fail("operator status", reason)
end
