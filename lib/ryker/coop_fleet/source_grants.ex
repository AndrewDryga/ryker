defmodule Ryker.CoopFleet.SourceGrants do
  @moduledoc false

  import Ecto.Query

  require Logger

  alias Ryker.CoopFleet.{ControlPlane, JobSpec, Placement}
  alias Ryker.GitHub.InstallationTokens
  alias Ryker.{Repo, Settings}
  alias Ryker.Work.Session

  @identity ~w(repository_ref github_repository github_repository_id)

  @doc "A fresh Contents:read grant only for a repository in the leased worker's frozen job."
  @spec source_grant(binary(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def source_grant(certificate, job_ref, source, provider \\ InstallationTokens) do
    with {:ok, binding, ^source} <- source_grant_authority(certificate, job_ref, source),
         {:ok, %{token: token, expires_at: expires_at}} <-
           InstallationTokens.fresh_source_token(
             provider,
             binding.name,
             Map.delete(binding, :name)
           ),
         # Minting is external I/O. Revocation, replacement or settings changes during it
         # must not release a credential to a worker which no longer owns the job.
         {:ok, ^binding, ^source} <- source_grant_authority(certificate, job_ref, source) do
      {:ok,
       %{
         "repository_ref" => source["repository_ref"],
         "github_repository" => source["github_repository"],
         "github_repository_id" => source["github_repository_id"],
         "token" => token,
         "expires_at" => DateTime.to_iso8601(expires_at)
       }}
    else
      refused ->
        # The worker only hears 404, so this is the one place that says why a
        # job could not fetch its repository. Never the token: it was not issued.
        Logger.warning(
          "Coop job source grant refused for #{job_ref}: #{inspect(refused, limit: 12)}"
        )

        {:error, :coop_worker_source_grant_not_authorized}
    end
  end

  @doc false
  @spec source_grant_authority(binary(), String.t(), map()) ::
          {:ok, map(), map()} | {:error, term()}
  def source_grant_authority(certificate, job_ref, source)
      when is_binary(job_ref) and byte_size(job_ref) in 1..256 and is_map(source) do
    with {:ok, worker_id} <- ControlPlane.authenticate_certificate(certificate),
         [%Session{worker_job_document: job, worker_job_digest: digest}] <-
           leased_sessions(worker_id, job_ref),
         true <- job["job_ref"] == job_ref,
         {:ok, ^digest} <- JobSpec.digest(job),
         true <- Enum.sort(Map.keys(source)) == Enum.sort(@identity),
         true <-
           Enum.any?(
             [job["source"] | Enum.map(job["companions"], & &1["source"])],
             &grants_repository?(&1, source)
           ),
         {:ok, snapshot} <- Settings.fetch(),
         %{repository_id: repository_id} = binding <-
           Enum.find(snapshot.github_bindings, &(&1.repository_ref == source["repository_ref"])),
         %{github_repository: github_repository, github_access: :available} <-
           Enum.find(snapshot.repositories, &(&1.ref == source["repository_ref"])),
         true <-
           github_repository == source["github_repository"] and
             repository_id == source["github_repository_id"] do
      {:ok, Map.take(binding, [:name, :repository_id, :installation_id]), source}
    else
      _invalid -> {:error, :coop_worker_source_grant_not_authorized}
    end
  end

  def source_grant_authority(_certificate, _job_ref, _source),
    do: {:error, :coop_worker_source_grant_not_authorized}

  defp grants_repository?(nil, _identity), do: false

  defp grants_repository?(source, identity) do
    Map.take(source, @identity) == identity or
      Enum.any?(source["submodules"], &grants_repository?(&1, identity))
  end

  defp leased_sessions(worker_id, job_ref) do
    now = Repo.now!()

    # Job references identify an execution generation, not its reusable task.
    # Refuse ambiguous authority even if two current sessions have the same ref.
    Repo.all(
      from(session in Session,
        join: placement in Placement,
        on: placement.session_id == session.id,
        where:
          session.external_ref == ^job_ref and placement.worker_id == ^worker_id and
            placement.state == :active and placement.lease_expires_at > ^now,
        limit: 2,
        select: session
      )
    )
  end
end
