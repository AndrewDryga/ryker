defmodule Mix.Tasks.Ryker.Flywheel do
  @shortdoc "Runs a flywheel operator request from a JSON file or standard input"
  @moduledoc """
  Reads one bounded JSON request. Starts only the repository, never Ryker's
  workers. `mix ryker.flywheel request.json`, or `mix ryker.flywheel -`.
  The installed release uses `scripts/flywheel.sh` with the same document.
  """
  use Mix.Task
  alias Mix.Tasks.Ryker.OperatorSupport, as: Support
  alias Ryker.Flywheel

  @impl Mix.Task
  def run([path]) do
    with {:ok, bytes} <- read(path),
         {:ok, request} <- Jason.decode(bytes),
         {:ok, result} <- Support.with_repo(fn -> Flywheel.execute(request) end) do
      Support.print(result)
    else
      {:error, reason} -> Support.fail("flywheel", reason)
    end
  end

  def run(_arguments), do: Mix.raise("usage: mix ryker.flywheel REQUEST.json|-")
  defp read("-"), do: {:ok, IO.read(:stdio, 8_000_001)}
  defp read(path), do: File.read(path)
end
