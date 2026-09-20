defmodule Mix.Tasks.Ryker.Credentials.Import do
  @moduledoc "Imports retired integration environment credentials into encrypted custody."
  use Mix.Task

  alias Ryker.Credentials.LegacyImporter

  @shortdoc "Imports retired integration environment credentials into encrypted custody"

  @impl Mix.Task
  def run([]) do
    Mix.Task.run("app.start")

    case LegacyImporter.run() do
      {:ok, report} ->
        Mix.shell().info(
          "credential import: #{length(report.imported)} imported, " <>
            "#{length(report.present)} already present, #{length(report.conflicts)} conflicts, " <>
            "#{length(report.invalid)} invalid"
        )

        if report.conflicts != [] or report.invalid != [] do
          Mix.raise("credential import needs operator resolution")
        end

      {:error, reason} ->
        Mix.raise("credential import failed: #{inspect(reason)}")
    end
  end

  def run(_arguments), do: Mix.raise("usage: mix ryker.credentials.import")
end
