defmodule Ryker.GitHub.Client.Actions do
  @moduledoc """
  GitHub Actions workflow runs, one exact attempt at a time: read the attempt
  and its bounded jobs, rerun its failed jobs, or cancel it.

  A rerun or cancel names the attempt it was decided on, and is refused when a
  newer attempt has started or the run is no longer in a state the action
  applies to, so a decision is never carried out against a run nobody saw.
  """

  alias Ryker.GitHub.Client.{Fields, Transport}

  def read_ci_attempt(client, repository, run_id, attempt) do
    with :ok <- Fields.target(repository, run_id),
         :ok <- Fields.positive_id(attempt),
         {:ok, run_response} <-
           Transport.request(
             client,
             :get,
             "/repos/#{repository}/actions/runs/#{run_id}/attempts/#{attempt}",
             nil
           ),
         {:ok, run} <- ci_run(run_response, repository, run_id, attempt),
         {:ok, jobs_response} <-
           Transport.request(
             client,
             :get,
             "/repos/#{repository}/actions/runs/#{run_id}/attempts/#{attempt}/jobs?per_page=100",
             nil
           ),
         {:ok, jobs} <- ci_jobs(jobs_response, repository) do
      {:ok,
       %{
         "attempt" => attempt,
         "artifacts_path" => "/repos/#{repository}/actions/runs/#{run_id}/artifacts",
         "jobs" => jobs,
         "repository" => repository,
         "run" => run,
         "run_id" => run_id
       }}
    end
  end

  def rerun_failed_ci(client, repository, run_id, attempt) do
    with {:ok, current} <- current_ci_attempt(client, repository, run_id, attempt),
         true <- current["status"] == "completed",
         {:ok, response} <-
           Transport.request(
             client,
             :post,
             "/repos/#{repository}/actions/runs/#{run_id}/rerun-failed-jobs",
             %{}
           ) do
      case response do
        %{status: 201} ->
          {:ok,
           %{
             "previous_attempt" => attempt,
             "requested_attempt" => attempt + 1,
             "run_id" => run_id,
             "status" => "queued"
           }}

        other ->
          Transport.error(other)
      end
    else
      false -> {:error, {:github_action_unavailable, :run_not_completed}}
      {:error, _reason} = error -> error
    end
  end

  def cancel_ci(client, repository, run_id, attempt) do
    with {:ok, current} <- current_ci_attempt(client, repository, run_id, attempt),
         true <- current["status"] in ~w(queued in_progress pending requested waiting),
         {:ok, response} <-
           Transport.request(
             client,
             :post,
             "/repos/#{repository}/actions/runs/#{run_id}/cancel",
             %{}
           ) do
      case response do
        %{status: 202} ->
          {:ok, %{"attempt" => attempt, "run_id" => run_id, "status" => "cancelling"}}

        other ->
          Transport.error(other)
      end
    else
      false -> {:error, {:github_action_unavailable, :run_not_active}}
      {:error, _reason} = error -> error
    end
  end

  defp current_ci_attempt(client, repository, run_id, attempt) do
    with :ok <- Fields.target(repository, run_id),
         :ok <- Fields.positive_id(attempt),
         {:ok, response} <-
           Transport.request(client, :get, "/repos/#{repository}/actions/runs/#{run_id}", nil) do
      case response do
        %{body: %{"run_attempt" => ^attempt}, status: 200} ->
          ci_run(response, repository, run_id, attempt)

        %{body: %{"run_attempt" => current}, status: 200}
        when is_integer(current) and current > 0 ->
          {:error, {:github_action_unavailable, :stale_attempt}}

        other ->
          ci_run(other, repository, run_id, attempt)
      end
    end
  end

  defp ci_run(
         %{
           body: %{
             "conclusion" => conclusion,
             "head_sha" => head_sha,
             "html_url" => url,
             "id" => run_id,
             "repository" => %{"full_name" => repository},
             "run_attempt" => attempt,
             "status" => status
           },
           status: 200
         },
         repository,
         run_id,
         attempt
       )
       when status in ~w(queued in_progress completed pending requested waiting) do
    with :ok <- Fields.sha(head_sha),
         :ok <- Fields.context_url(url),
         true <- is_nil(conclusion) or is_binary(conclusion) do
      {:ok,
       %{
         "attempt" => attempt,
         "conclusion" => conclusion,
         "head_sha" => head_sha,
         "status" => status,
         "url" => url
       }}
    else
      _invalid -> {:error, {:github_protocol_error, :workflow_run}}
    end
  end

  defp ci_run(%{status: 200}, _repository, _run_id, _attempt),
    do: {:error, {:github_protocol_error, :workflow_run}}

  defp ci_run(response, _repository, _run_id, _attempt), do: Transport.error(response)

  defp ci_jobs(%{body: %{"jobs" => jobs, "total_count" => total}, status: 200}, repository)
       when is_list(jobs) and is_integer(total) and total >= 0 and total <= 100 do
    jobs
    |> Enum.reduce_while({:ok, []}, fn job, {:ok, prepared} ->
      case ci_job(job, repository) do
        {:ok, result} -> {:cont, {:ok, [result | prepared]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, prepared} -> {:ok, Enum.reverse(prepared)}
      {:error, _reason} = error -> error
    end
  end

  defp ci_jobs(%{status: 200}, _repository),
    do: {:error, {:github_protocol_error, :workflow_jobs}}

  defp ci_jobs(response, _repository), do: Transport.error(response)

  defp ci_job(
         %{
           "completed_at" => completed_at,
           "conclusion" => conclusion,
           "head_sha" => head_sha,
           "html_url" => url,
           "id" => id,
           "name" => name,
           "started_at" => started_at,
           "status" => status,
           "steps" => steps
         },
         repository
       )
       when is_integer(id) and id > 0 and is_binary(name) and is_list(steps) and
              status in ~w(queued in_progress completed pending requested waiting) do
    with :ok <- Fields.sha(head_sha),
         :ok <- Fields.context_url(url),
         true <- is_nil(conclusion) or is_binary(conclusion) do
      {:ok,
       %{
         "annotations_path" => "/repos/#{repository}/check-runs/#{id}/annotations",
         "completed_at" => completed_at,
         "conclusion" => conclusion,
         "id" => id,
         "logs_path" => "/repos/#{repository}/actions/jobs/#{id}/logs",
         "name" => name,
         "started_at" => started_at,
         "status" => status,
         "steps" => Enum.take(steps, 100),
         "url" => url
       }}
    else
      _invalid -> {:error, {:github_protocol_error, :workflow_job}}
    end
  end

  defp ci_job(_job, _repository), do: {:error, {:github_protocol_error, :workflow_job}}
end
