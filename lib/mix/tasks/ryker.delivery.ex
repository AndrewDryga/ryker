defmodule Mix.Tasks.Ryker.Delivery do
  @moduledoc """
  Inspects or rearms blocked platform messages, reactions, and model-requested actions.

      mix ryker.delivery list
      mix ryker.delivery show DELIVERY_REF
      mix ryker.delivery rearm DELIVERY_REF
  """

  use Mix.Task

  alias Ryker.Delivery.Operator
  alias Ryker.Repo

  @shortdoc "Lists, inspects, or rearms blocked delivery"

  @impl Mix.Task
  def run(arguments) do
    case arguments do
      ["list"] -> with_repo(&Operator.list_blocked/0)
      ["show", delivery_ref] -> with_repo(fn -> Operator.fetch(delivery_ref) end)
      ["rearm", delivery_ref] -> with_repo(fn -> Operator.rearm(delivery_ref) end)
      _invalid -> Mix.raise("usage: mix ryker.delivery list|show REF|rearm REF")
    end
  end

  defp with_repo(operation) do
    repo = Mix.Ecto.ensure_repo(Repo, [])

    case Ecto.Migrator.with_repo(repo, fn _repo -> operation.() end, mode: :temporary) do
      {:ok, result, _started_apps} -> print(result)
      {:error, reason} -> Mix.raise("could not start delivery repository: #{inspect(reason)}")
    end
  end

  defp print({:ok, value}), do: Mix.shell().info(Jason.encode!(value))
  defp print({:error, reason}), do: Mix.raise("delivery operation failed: #{inspect(reason)}")
end
