defmodule Mix.Tasks.Ryker.CoopWorker do
  @moduledoc """
  Manages one Coop worker's enrollment and operator-owned lifecycle.

      mix ryker.coop_worker enroll WORKER_ID WORKSPACE_REF OPERATOR_REF
      mix ryker.coop_worker enroll WORKER_ID WORKSPACE_REF OPERATOR_REF TTL_SECONDS
      mix ryker.coop_worker drain WORKER_ID OPERATOR_REF
      mix ryker.coop_worker resume WORKER_ID OPERATOR_REF
      mix ryker.coop_worker revoke WORKER_ID OPERATOR_REF

  The plaintext token is printed exactly once. Store it in the worker's private
  `enrollment_token_file`; the worker removes that file after enrollment.
  """

  use Mix.Task

  alias Ryker.CoopFleet.{Enrollment, WorkerLifecycle}
  alias Ryker.Repo

  @shortdoc "Enrolls, drains, resumes, or revokes a Coop worker"

  @impl Mix.Task
  def run(arguments) do
    case arguments do
      ["enroll", worker_id, workspace_ref, operator_ref] ->
        with_repo(fn -> Enrollment.issue_token(worker_id, workspace_ref, operator_ref) end)

      ["enroll", worker_id, workspace_ref, operator_ref, ttl] ->
        enroll_with_ttl(worker_id, workspace_ref, operator_ref, Integer.parse(ttl))

      ["drain", worker_id, operator_ref] ->
        lifecycle(fn -> WorkerLifecycle.drain(worker_id, operator_ref) end)

      ["resume", worker_id, operator_ref] ->
        lifecycle(fn -> WorkerLifecycle.resume(worker_id, operator_ref) end)

      ["revoke", worker_id, operator_ref] ->
        lifecycle(fn -> WorkerLifecycle.revoke(worker_id, operator_ref) end)

      _invalid ->
        usage!()
    end
  end

  defp enroll_with_ttl(worker_id, workspace_ref, operator_ref, {ttl, ""}) do
    with_repo(fn -> Enrollment.issue_token(worker_id, workspace_ref, operator_ref, ttl) end)
  end

  defp enroll_with_ttl(_worker_id, _workspace_ref, _operator_ref, _invalid), do: usage!()

  defp lifecycle(operation) do
    with_repo(operation, fn %{status: status, worker: worker} ->
      %{
        "drain_requested_at" => iso8601(worker.drain_requested_at),
        "drain_requested_by" => worker.drain_requested_by,
        "revoked_at" => iso8601(worker.revoked_at),
        "revoked_by" => worker.revoked_by,
        "state" => Atom.to_string(worker.state),
        "status" => Atom.to_string(status),
        "worker_id" => worker.id
      }
    end)
  end

  defp with_repo(operation, prepare \\ & &1) do
    repo = Mix.Ecto.ensure_repo(Repo, [])

    case Ecto.Migrator.with_repo(repo, fn _repo -> operation.() end, mode: :temporary) do
      {:ok, {:ok, value}, _started_apps} ->
        Mix.shell().info(Jason.encode!(prepare.(value)))

      {:ok, {:error, reason}, _started_apps} ->
        Mix.raise("worker enrollment failed: #{inspect(reason)}")

      {:error, reason} ->
        Mix.raise("could not start worker enrollment repository: #{inspect(reason)}")
    end
  end

  defp usage! do
    Mix.raise(
      "usage: mix ryker.coop_worker enroll WORKER_ID WORKSPACE_REF OPERATOR_REF [TTL_SECONDS] | " <>
        "mix ryker.coop_worker drain|resume|revoke WORKER_ID OPERATOR_REF"
    )
  end

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(nil), do: nil
end
