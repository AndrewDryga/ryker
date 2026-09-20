defmodule Mix.Tasks.Ryker.EmisarApproval do
  @moduledoc """
  Inspects or rearms a blocked Emisar approval monitor.

      mix ryker.emisar_approval list
      mix ryker.emisar_approval show CONNECTION/REQUEST_ID
      mix ryker.emisar_approval rearm CONNECTION/REQUEST_ID

  This command cannot approve, deny, repeat, or replace an Emisar action.
  """

  use Mix.Task

  alias Mix.Tasks.Ryker.OperatorSupport, as: Support
  alias Ryker.Emisar.Operator

  @shortdoc "Lists, inspects, or rearms blocked Emisar approval monitoring"

  @impl Mix.Task
  def run(arguments) do
    case arguments do
      ["list"] ->
        with_repo(&Operator.list_blocked/0)

      ["show", ref] ->
        with_repo(fn -> Operator.fetch(ref) end)

      ["rearm", ref] ->
        with_repo(fn -> Operator.rearm(ref) end)

      _invalid ->
        Mix.raise("usage: mix ryker.emisar_approval list|show CONNECTION/ID|rearm CONNECTION/ID")
    end
  end

  defp with_repo(operation), do: operation |> Support.with_repo() |> print_result()

  defp print_result({:ok, value}), do: Support.print(value)
  defp print_result({:error, reason}), do: Support.fail("Emisar approval operation", reason)
end
