defmodule Ryker.Work.CompletionReview.FleetSession do
  @moduledoc "A fresh reviewer inherits model targets, never the working session's authority."
  alias Ryker.CoopFleet
  alias Ryker.Repo
  alias Ryker.Work.CompletionReview.Run
  alias Ryker.Work.{Custody, Session}

  def external_ref(%Run{id: id}), do: "ryker-completion-review:#{id}"

  def ensure(%Run{} = run, %Session{worker_job_document: %{} = parent_job}) do
    external_ref = external_ref(run)

    with {:ok, job, digest} <- job(parent_job, external_ref) do
      changeset =
        Session.Changeset.completion_review(%{
          completion_review_id: run.id,
          policy: run.policy,
          policy_digest: run.policy_digest,
          external_ref: external_ref,
          worker_job_document: job,
          worker_job_digest: digest
        })

      Repo.insert(changeset)
    end
  end

  def ensure(_run, _parent), do: {:error, :completion_review_worker_job_missing}

  @doc "The exact restricted job, shared by production creation and evaluation authorization."
  def job(parent_job, external_ref) do
    limits =
      Map.merge(parent_job["limits"], %{
        "max_turns" => 1,
        "max_queued_turns" => 1,
        "turn_timeout_ms" => min(parent_job["limits"]["turn_timeout_ms"], 300_000),
        "warm_idle_timeout_ms" => 0
      })

    job =
      Map.merge(parent_job, %{
        "job_ref" => external_ref,
        "source" => nil,
        "companions" => [],
        "mode" => "normal",
        "repository_read_only" => true,
        "environment" => %{},
        "check" => %{"argv" => [], "environment" => %{}},
        "egress" => CoopFleet.JobTemplates.provider_only_egress(),
        "limits" => limits
      })

    with {:ok, digest} <- CoopFleet.JobSpec.digest(job), do: {:ok, job, digest}
  end

  def fetch_for_run(%Run{id: id}), do: Repo.fetch(Session.Query.by_completion_review_id(id))

  def bind(%Run{} = run, remote_id) do
    with {:ok, session} <- fetch_for_run(run) do
      case session.coop_session_id do
        nil ->
          session
          |> Session.Changeset.bind_completion_review(remote_id)
          |> Repo.update()
          |> announce()

        ^remote_id ->
          {:ok, session}

        _other ->
          {:error, :completion_review_session_identity_conflict}
      end
    end
  end

  defp announce({:ok, session}) do
    Custody.broadcast_session_updated(session)
    {:ok, session}
  end

  defp announce({:error, reason}), do: {:error, reason}
end
