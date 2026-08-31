defmodule Mix.Tasks.Responder.Cutover do
  @moduledoc """
  Runs the explicit one-shot replacement cutover workflow.

      mix responder.cutover inventory SQLITE_SNAPSHOT MANIFEST WORKSPACE_REF CUTOVER_AT
      mix responder.cutover prepare MANIFEST REVIEW
      mix responder.cutover apply RUN_ID CONFIG
      mix responder.cutover rollback RUN_ID OPERATOR_REF

  Inventory never starts Responder, mutates PostgreSQL, or reads a live SQLite
  database. The other commands start only a temporary Repo process; they never
  start admission, Work, delivery, or a platform listener.
  """

  use Mix.Task

  alias Responder.Cutover.{Importer, Ledger, Manifest, Rollback}
  alias Responder.{Repo, RuntimeConfiguration}

  @shortdoc "Inventories, prepares, applies, or rolls back the one-time Elixir cutover"
  @maximum_manifest_bytes 16 * 1_024 * 1_024
  @maximum_review_bytes 1 * 1_024 * 1_024

  @impl Mix.Task
  def run(["inventory", source, destination, workspace_ref, cutover_at]) do
    with {:ok, timestamp} <- utc_datetime(cutover_at),
         {:ok, result} <-
           Manifest.create(source, destination,
             cutover_at: timestamp,
             workspace_ref: workspace_ref
           ) do
      Mix.shell().info(
        Jason.encode!(%{
          "bytes" => result.bytes,
          "path" => result.path,
          "sha256" => result.sha256,
          "status" => "inventoried"
        })
      )
    else
      {:error, reason} -> Mix.raise("cutover inventory failed: #{inspect(reason)}")
    end
  end

  def run(["prepare", manifest_path, review_path]) do
    with {:ok, manifest} <- read_json(manifest_path, @maximum_manifest_bytes),
         {:ok, review} <- read_json(review_path, @maximum_review_bytes) do
      with_repo(fn -> Ledger.prepare(manifest, review) end)
      |> print_result("prepared")
    else
      {:error, reason} -> Mix.raise("cutover prepare failed: #{inspect(reason)}")
    end
  end

  def run(["apply", run_id, configuration_path]) do
    configuration = RuntimeConfiguration.load!(configuration_path)
    profiles = Map.fetch!(configuration, :cutover_profiles)

    with_repo(fn -> Importer.apply(run_id, work_profiles: profiles) end)
    |> print_result("applied")
  end

  def run(["rollback", run_id, operator_ref]) do
    with_repo(fn -> Rollback.rollback(run_id, operator_ref) end)
    |> print_result("rolled_back")
  end

  def run(_arguments), do: usage!()

  defp utc_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{} = timestamp, 0} -> {:ok, timestamp}
      _invalid -> {:error, :cutover_timestamp_must_be_utc_iso8601}
    end
  end

  defp read_json(path, maximum) when is_binary(path) do
    with true <- Path.type(path) == :absolute,
         {:ok, %File.Stat{type: :regular, size: size}} when size <= maximum <- File.lstat(path),
         {:ok, document} <- File.read(path),
         {:ok, %{} = decoded} <- Jason.decode(document) do
      {:ok, decoded}
    else
      _invalid -> {:error, :cutover_artifact_file_invalid}
    end
  end

  defp read_json(_path, _maximum), do: {:error, :cutover_artifact_file_invalid}

  defp with_repo(operation) do
    repo = Mix.Ecto.ensure_repo(Repo, [])

    case Ecto.Migrator.with_repo(repo, fn _repo -> operation.() end, mode: :temporary) do
      {:ok, result, _started_apps} -> result
      {:error, reason} -> Mix.raise("could not start cutover repository: #{inspect(reason)}")
    end
  end

  defp print_result({:ok, %{run: run, status: status}}, operation) do
    Mix.shell().info(
      Jason.encode!(%{
        "operation" => operation,
        "run_id" => run.id,
        "status" => Atom.to_string(status)
      })
    )
  end

  defp print_result({:error, reason}, operation),
    do: Mix.raise("cutover #{operation} failed: #{inspect(reason)}")

  defp usage! do
    Mix.raise(
      "usage: mix responder.cutover inventory SQLITE_SNAPSHOT MANIFEST WORKSPACE_REF CUTOVER_AT | " <>
        "prepare MANIFEST REVIEW | apply RUN_ID CONFIG | rollback RUN_ID OPERATOR_REF"
    )
  end
end
