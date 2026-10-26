defmodule Ryker.Flywheel do
  @moduledoc """
  The operator skill's durable improvement ledger. The skill reasons and uses
  normal development tools; this boundary records coverage and decisions. It
  never calls a model, edits settings, or executes a proposed command.
  """
  alias Ryker.Flywheel.{Findings, Protocol, Run, Runs, Sources}
  alias Ryker.Repo

  @doc "Executes a bounded operator request: `{:ok, document}` or `{:error, reason}`. Host shell access is the authority."
  def execute(request) when is_map(request) do
    if byte_size(Jason.encode!(request)) > 8_000_000 do
      {:error, :flywheel_request_too_large}
    else
      with {:ok, result} <- dispatch(request), do: {:ok, Protocol.document(result)}
    end
  end

  def execute(_request), do: {:error, :invalid_flywheel_request}

  defp dispatch(%{"action" => "start"} = request), do: Runs.start(request)
  defp dispatch(%{"action" => "catalog"}), do: {:ok, Sources.catalog()}

  defp dispatch(%{"action" => "report"}),
    do: {:ok, %{runs: Repo.all(Run.Query.ordered_by_oldest()), findings: Findings.report()}}

  defp dispatch(%{"action" => "resume", "run_id" => id} = request) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Runs.resume(id, request["lease_ref"])
      :error -> {:error, :invalid_flywheel_run_id}
    end
  end

  defp dispatch(%{"action" => action, "run_id" => id, "lease_ref" => lease_ref} = request) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Runs.with_run(id, lease_ref, &within_run(&1, action, request))
      :error -> {:error, :invalid_flywheel_run_id}
    end
  end

  defp dispatch(_request), do: {:error, :invalid_flywheel_request}

  defp within_run(run, "heartbeat", _request), do: Runs.renew(run, %{})
  defp within_run(run, "collect", request), do: Runs.collect(run, request["source"])
  defp within_run(run, "stage", request), do: Runs.stage(run, request["source"], request["page"])

  defp within_run(run, "review", request),
    do: Runs.review(run, request["source"], request["digest"], request["findings"])

  defp within_run(run, "gap", request) do
    Runs.gap(
      run,
      request["source"],
      request["status"],
      request["reason"],
      Map.get(request, "closed", false)
    )
  end

  defp within_run(run, "charge", request),
    do: Runs.charge(run, request["source"], request["reference"], request["amount_usd"])

  defp within_run(run, "finish", _request), do: Runs.finish(run)

  defp within_run(run, "decide", request) do
    case Ecto.UUID.cast(request["finding_id"]) do
      {:ok, id} -> Findings.transition(run, id, request["decision"], request)
      :error -> Repo.rollback(:invalid_flywheel_finding_id)
    end
  end

  defp within_run(_run, _action, _request), do: Repo.rollback(:invalid_flywheel_request)
end
