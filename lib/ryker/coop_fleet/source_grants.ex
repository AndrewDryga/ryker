defmodule Ryker.CoopFleet.SourceGrants do
  @moduledoc false
  alias Ryker.CoopFleet.{ControlPlane, JobSpec}
  alias Ryker.GitHub
  alias Ryker.{Maps, Repo, Settings}
  alias Ryker.Work
  require Logger

  @identity ~w(repository_ref github_repository github_repository_id)

  # A grant without a credential is only a promise that Ryker will not object.
  @public_grant_seconds 3_600

  @doc """
  A fresh Contents:read grant only for a repository in the leased worker's
  frozen job. A public repository the job vendors as a submodule, and Ryker
  was never given, is read by anyone: its grant carries no credential and says
  so (`"public"`), and the worker fetches it anonymously.
  """
  @spec source_grant(binary(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def source_grant(certificate, job_ref, source, provider \\ GitHub.InstallationTokens) do
    case source_grant_authority(certificate, job_ref, source) do
      {:ok, :public} -> {:ok, public_grant(source)}
      authority -> minted_grant(authority, certificate, job_ref, source, provider)
    end
  end

  defp public_grant(source) do
    %{
      "repository_ref" => source["repository_ref"],
      "github_repository" => source["github_repository"],
      "github_repository_id" => source["github_repository_id"],
      "token" => "",
      "public" => true,
      "expires_at" =>
        Repo.now!() |> DateTime.add(@public_grant_seconds, :second) |> DateTime.to_iso8601()
    }
  end

  defp minted_grant(authority, certificate, job_ref, source, provider) do
    with {:ok, binding} <- authority,
         installation = Map.delete(binding, :name),
         {:ok, %{token: token, expires_at: expires_at}} <-
           GitHub.InstallationTokens.fresh_source_token(provider, binding.name, installation),
         # Minting is external I/O. Revocation, replacement or settings changes during it
         # must not release a credential to a worker which no longer owns the job.
         {:ok, ^binding} <- source_grant_authority(certificate, job_ref, source) do
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
        # The worker only hears 404 or 503, so this is the one place that says why
        # a job could not fetch its repository. Never the token: it was not issued.
        Logger.warning(
          "Coop job source grant refused for #{job_ref}: #{inspect(refused, limit: 12)}"
        )

        if for_now?(refused),
          do: {:error, :coop_worker_source_grant_unavailable},
          else: {:error, :coop_worker_source_grant_not_authorized}
    end
  end

  # GitHub busy or silent may answer the worker's next try; one that refused the
  # token, or a binding that changed, refuses again. Told "not found" when GitHub
  # answered a token request with 503, tenant's worker failed a create for good
  # (2026-10-03).
  defp for_now?({:error, {:github_installation_token_unavailable, reason}}),
    do: token_for_now?(reason)

  defp for_now?(_refused), do: false

  defp token_for_now?({:http_status, status}), do: status >= 500 or status in [408, 429]
  defp token_for_now?(reason), do: reason not in [:binding, :purpose]

  @doc false
  @spec source_grant_authority(binary(), String.t(), map()) ::
          {:ok, map() | :public} | {:error, term()}
  def source_grant_authority(certificate, job_ref, source)
      when is_binary(job_ref) and byte_size(job_ref) in 1..256 and is_map(source) do
    with {:ok, worker_id} <- ControlPlane.authenticate_certificate(certificate),
         [%Work.Session{worker_job_document: job, worker_job_digest: digest}] <-
           leased_sessions(worker_id, job_ref),
         true <- job["job_ref"] == job_ref,
         {:ok, ^digest} <- JobSpec.digest(job),
         true <- Maps.exact_keys?(source, @identity),
         true <-
           Enum.any?(
             [job["source"] | Enum.map(job["companions"], & &1["source"])],
             &grants_repository?(&1, source)
           ),
         {:ok, binding} <- grant_binding(source) do
      {:ok, binding}
    else
      invalid ->
        Logger.warning(
          "Coop job source grant authority refused for #{job_ref}: " <>
            refusal(invalid) <> " (source keys #{inspect(Map.keys(source))})"
        )

        {:error, :coop_worker_source_grant_not_authorized}
    end
  end

  def source_grant_authority(_certificate, _job_ref, _source),
    do: {:error, :coop_worker_source_grant_not_authorized}

  # Which check refused, without the job document or any credential.
  defp refusal([]), do: "no current session holds this job on this worker"
  defp refusal([_one, _two]), do: "two current sessions hold this job"
  defp refusal(false), do: "a job, source or repository check did not match"
  defp refusal(nil), do: "the repository has no GitHub binding or is not available"
  defp refusal({:error, reason}), do: inspect(reason, limit: 8)
  defp refusal({:ok, _other}), do: "the job document's digest does not match"
  defp refusal(other), do: inspect(other, limit: 3, printable_limit: 200)

  defp grants_repository?(nil, _identity), do: false

  # A public repository is only ever a submodule the job vendors: Ryker pins
  # one only for that, never as a source of its own.
  defp grants_repository?(source, %{"repository_ref" => "public:" <> _} = identity),
    do: Enum.any?(source["submodules"], &vendors?(&1, identity))

  defp grants_repository?(source, identity) do
    Map.take(source, @identity) == identity or
      Enum.any?(source["submodules"], &grants_repository?(&1, identity))
  end

  defp vendors?(module, identity) do
    Map.take(module, @identity) == identity or
      Enum.any?(module["submodules"], &vendors?(&1, identity))
  end

  defp grant_binding(%{"repository_ref" => "public:" <> _}), do: {:ok, :public}

  defp grant_binding(source) do
    with {:ok, snapshot} <- Settings.fetch(),
         %{repository_id: repository_id} = binding <-
           Enum.find(snapshot.github_bindings, &(&1.repository_ref == source["repository_ref"])),
         %{github_repository: github_repository, github_access: :available} <-
           Enum.find(snapshot.repositories, &(&1.ref == source["repository_ref"])),
         true <-
           github_repository == source["github_repository"] and
             repository_id == source["github_repository_id"] do
      {:ok, Map.take(binding, [:name, :repository_id, :installation_id])}
    end
  end

  defp leased_sessions(worker_id, job_ref) do
    now = Repo.now!()

    # Job references identify an execution generation, not its reusable task.
    # Refuse ambiguous authority even if two current sessions have the same ref.
    Repo.all(Work.Session.Query.placed_job(job_ref, worker_id, now))
  end
end
