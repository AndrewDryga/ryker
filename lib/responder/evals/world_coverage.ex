defmodule Responder.Evals.WorldCoverage do
  @moduledoc """
  Compiles the required model-world job and failure coverage matrix.

  Coverage is evidence, not a tag count. Every covered cell names a checked-in
  scenario that the deterministic and model-world runners can load. Empty cells
  stay visible until a real scenario closes them.
  """

  alias Responder.Evals.WorldCase

  @root "testdata/scenarios"
  @maximum_bytes 64 * 1_024
  @root_fields ~w(failure_axes jobs version)
  @required_jobs ~w(
    application_errors artifacts automation_waits creative_requests engineering_work grafana
    github_review incident_response memory_feedback multi_user_threads ordinary_conversation research
    terraform uptime
  )
  @required_failure_axes ~w(
    concurrent_human_feedback denied_authority missing_stale_contradictory_evidence noisy_context
    process_restart rate_limit reconnect source_lifecycle_changes uncertain_delivery worker_loss
  )

  @type report :: %{
          complete?: boolean(),
          failure_axes: %{String.t() => [String.t()]},
          jobs: %{String.t() => [String.t()]},
          missing_failure_axes: [String.t()],
          missing_jobs: [String.t()]
        }

  @spec report(Path.t()) :: {:ok, report()} | {:error, term()}
  def report(root \\ @root)

  def report(root) when is_binary(root) do
    with {:ok, document} <- read(Path.join(root, "coverage.json")),
         {:ok, scenarios} <- WorldCase.all(root) do
      compile(document, MapSet.new(scenarios, & &1.id))
    end
  end

  def report(_root), do: {:error, {:invalid_world_coverage, :root}}

  @spec complete(Path.t()) :: :ok | {:error, term()}
  def complete(root \\ @root) do
    with {:ok, report} <- report(root) do
      if report.complete?,
        do: :ok,
        else:
          {:error,
           {:world_coverage_incomplete,
            %{failure_axes: report.missing_failure_axes, jobs: report.missing_jobs}}}
    end
  end

  @spec required_jobs() :: [String.t()]
  def required_jobs, do: @required_jobs

  @spec required_failure_axes() :: [String.t()]
  def required_failure_axes, do: @required_failure_axes

  defp read(path) do
    with {:ok, bytes} <- File.read(path),
         true <- byte_size(bytes) <= @maximum_bytes,
         {:ok, %{} = document} <- Jason.decode(bytes) do
      {:ok, document}
    else
      {:ok, _other} -> {:error, {:invalid_world_coverage, :json_object}}
      {:error, reason} -> {:error, {:invalid_world_coverage, reason}}
      false -> {:error, {:invalid_world_coverage, :too_large}}
    end
  end

  defp compile(document, scenario_ids) do
    with :ok <- exact_fields(document, @root_fields, :document),
         true <- document["version"] == 1 or {:error, :version},
         {:ok, jobs} <- matrix(document["jobs"], @required_jobs, scenario_ids, :jobs),
         {:ok, failure_axes} <-
           matrix(
             document["failure_axes"],
             @required_failure_axes,
             scenario_ids,
             :failure_axes
           ) do
      missing_jobs = missing(jobs)
      missing_failure_axes = missing(failure_axes)

      {:ok,
       %{
         complete?: missing_jobs == [] and missing_failure_axes == [],
         failure_axes: failure_axes,
         jobs: jobs,
         missing_failure_axes: missing_failure_axes,
         missing_jobs: missing_jobs
       }}
    else
      {:error, field} -> {:error, {:invalid_world_coverage, field}}
      false -> {:error, {:invalid_world_coverage, :document}}
    end
  end

  defp matrix(value, required, scenario_ids, field) when is_map(value) do
    with :ok <- exact_fields(value, required, field),
         true <-
           Enum.all?(value, fn {_name, ids} -> scenario_ids(ids, scenario_ids) end) or
             {:error, field} do
      {:ok, Map.new(value, fn {name, ids} -> {name, Enum.sort(ids)} end)}
    end
  end

  defp matrix(_value, _required, _scenario_ids, field), do: {:error, field}

  defp scenario_ids(ids, available) when is_list(ids) and length(ids) <= 64 do
    Enum.uniq(ids) == ids and Enum.all?(ids, &MapSet.member?(available, &1))
  end

  defp scenario_ids(_ids, _available), do: false

  defp missing(matrix) do
    matrix
    |> Enum.filter(fn {_name, scenario_ids} -> scenario_ids == [] end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp exact_fields(value, fields, _field) when is_map(value) do
    if Enum.sort(Map.keys(value)) == Enum.sort(fields), do: :ok, else: {:error, :fields}
  end

  defp exact_fields(_value, _fields, field), do: {:error, field}
end
