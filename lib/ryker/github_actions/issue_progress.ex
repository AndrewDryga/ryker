defmodule Ryker.GitHubActions.IssueProgress do
  @moduledoc "Issue progress comes from admitted work and confirmed publication, then freezes its outcome."
  alias Ryker.GitHubActions.IssueRequest
  alias Ryker.Ingress
  alias Ryker.Records
  alias Ryker.Repo

  @doc "The accepted implementation for a plan, including plans started by earlier releases."
  def fetch_implementation(workflow_id, plan_id) do
    workflow_id
    |> IssueRequest.Query.by_workflow_id()
    |> IssueRequest.Query.plan_implementation(plan_id)
    |> Repo.fetch()
  end

  def displayed_request(%IssueRequest{kind: :implement_plan} = request) do
    case fetch_implementation(request.workflow_id, request.plan_id) do
      {:ok, original} -> original
      {:error, :not_found} -> request
    end
  end

  def displayed_request(request), do: request

  def read(nil), do: %{"status" => "ready"}
  def read(%IssueRequest{outcome: %{} = outcome}), do: outcome

  def read(%IssueRequest{} = request) do
    case Repo.fetch(Ingress.Inbox.Entry.Query.by_id(request.entry_id)) do
      {:ok, entry} -> progress(request, entry)
      {:error, :not_found} -> %{"status" => "history_unavailable", "terminal" => true}
    end
  end

  @doc "Called under workflow custody. Only a terminal result is stored, and only once."
  def refresh(nil), do: nil
  def refresh(%IssueRequest{outcome: %{} = _outcome} = request), do: request

  def refresh(request) do
    case read(request) do
      %{"terminal" => true} = result ->
        request |> IssueRequest.Changeset.finish(result, Repo.now!()) |> Repo.update!()

      _pending ->
        request
    end
  end

  defp progress(%{kind: kind}, entry) when kind in [:make_plan, :triage_issue],
    do: Records.TaskProgress.input(entry, "planning")

  defp progress(_request, entry), do: Records.TaskProgress.read(entry)
end
