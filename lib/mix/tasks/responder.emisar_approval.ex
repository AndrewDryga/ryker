defmodule Mix.Tasks.Responder.EmisarApproval do
  @moduledoc """
  Inspects or rearms a blocked Emisar approval monitor.

      mix responder.emisar_approval list
      mix responder.emisar_approval show REQUEST_ID
      mix responder.emisar_approval rearm REQUEST_ID

  This command cannot approve, deny, repeat, or replace an Emisar action.
  """

  use Mix.Task

  alias Responder.Emisar.Operator
  alias Responder.Repo

  @shortdoc "Lists, inspects, or rearms blocked Emisar approval monitoring"

  @impl Mix.Task
  def run(arguments) do
    case arguments do
      ["list"] -> with_repo(&Operator.list_blocked/0)
      ["show", request_id] -> with_repo(fn -> Operator.fetch(request_id) end)
      ["rearm", request_id] -> with_repo(fn -> Operator.rearm(request_id) end)
      _invalid -> Mix.raise("usage: mix responder.emisar_approval list|show ID|rearm ID")
    end
  end

  defp with_repo(operation) do
    repo = Mix.Ecto.ensure_repo(Repo, [])

    case Ecto.Migrator.with_repo(repo, fn _repo -> operation.() end, mode: :temporary) do
      {:ok, result, _started_apps} -> print(result)
      {:error, reason} -> Mix.raise("could not start Emisar repository: #{inspect(reason)}")
    end
  end

  defp print({:ok, value}), do: Mix.shell().info(Jason.encode!(value))

  defp print({:error, reason}),
    do: Mix.raise("Emisar approval operation failed: #{inspect(reason)}")
end
