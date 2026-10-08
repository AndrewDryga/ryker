defmodule Mix.Tasks.Ryker.Delivery do
  @shortdoc "Lists, inspects, or rearms blocked delivery"
  @moduledoc """
  Inspects or rearms blocked platform messages, routing responses, and model-requested actions.

      mix ryker.delivery list
      mix ryker.delivery show DELIVERY_REF
      mix ryker.delivery rearm DELIVERY_REF
  """
  use Mix.Task
  alias Mix.Tasks.Ryker.OperatorSupport, as: Support
  alias Ryker.Operator

  @impl Mix.Task
  def run(["list"]), do: with_repo(&Operator.Delivery.list_blocked/0)
  def run(["show", delivery_ref]), do: with_repo(fn -> Operator.Delivery.fetch(delivery_ref) end)
  def run(["rearm", delivery_ref]), do: with_repo(fn -> Operator.Delivery.rearm(delivery_ref) end)
  def run(_arguments), do: Mix.raise("usage: mix ryker.delivery list|show REF|rearm REF")

  defp with_repo(operation), do: operation |> Support.with_repo() |> print_result()

  defp print_result({:ok, value}), do: Support.print(value)
  defp print_result({:error, reason}), do: Support.fail("delivery operation", reason)
end
