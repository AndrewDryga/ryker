defmodule Mix.Tasks.Ryker.EmisarApproval do
  @moduledoc """
  Inspects or rearms a blocked Emisar approval monitor.

      mix ryker.emisar_approval list
      mix ryker.emisar_approval show REQUEST_ID
      mix ryker.emisar_approval rearm REQUEST_ID

  This command cannot approve, deny, repeat, or replace an Emisar action.
  """

  use Mix.Task

  alias Mix.Tasks.Ryker.OperatorSupport, as: Support
  alias Ryker.Emisar.Operator

  @shortdoc "Lists, inspects, or rearms blocked Emisar approval monitoring"

  @impl Mix.Task
  def run(arguments) do
    case arguments do
      ["list"] -> with_repo(&Operator.list_blocked/0)
      ["show", request_id] -> with_repo(fn -> Operator.fetch(request_id) end)
      ["rearm", request_id] -> with_repo(fn -> Operator.rearm(request_id) end)
      _invalid -> Mix.raise("usage: mix ryker.emisar_approval list|show ID|rearm ID")
    end
  end

  defp with_repo(operation), do: operation |> Support.with_repo() |> print_result()

  defp print_result({:ok, value}), do: Support.print(value)
  defp print_result({:error, reason}), do: Support.fail("Emisar approval operation", reason)
end
