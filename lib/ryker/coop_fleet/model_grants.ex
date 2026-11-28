defmodule Ryker.CoopFleet.ModelGrants do
  @moduledoc "Expiring model proxy capabilities for a leased Coop execution."
  alias Ryker.{AdvisoryLock, Config, Crypto, Maps, Repo, Work}
  alias Ryker.CoopFleet.{Certificate, JobSpec, ModelAccounts, ModelRun, Placement, Worker}

  @request ~w(job_digest run_id provider account)
  @grant_seconds 120

  def issue(certificate, job_ref, request) when is_map(request) do
    with true <- Maps.exact_keys?(request, @request),
         true <- valid_run?(request["run_id"]),
         {:ok, {worker, worker_epoch}} <- fetch_authenticated_worker(certificate),
         {:ok, session, placement} <- authority(worker, job_ref),
         true <- session.worker_job_digest == request["job_digest"],
         true <-
           account_allowed?(session.worker_job_document, request["provider"], request["account"]),
         {:ok, metadata} <- ModelAccounts.metadata(request["provider"], request["account"]) do
      issue_current(worker, worker_epoch, job_ref, placement, request, metadata)
    else
      {:error, reason}
      when reason in [
             :model_renewal_needs_reconciliation,
             :model_access_expired,
             :model_issued_response_needs_reconciliation
           ] ->
        {:error, :model_grant_unavailable}

      _refused ->
        {:error, :model_grant_refused}
    end
  end

  def issue(_certificate, _job, _request), do: {:error, :model_grant_refused}

  defp issue_current(worker, worker_epoch, job_ref, placement, request, metadata) do
    Repo.transaction(fn ->
      AdvisoryLock.hold!("model-grant:#{placement.id}:#{request["run_id"]}")

      with {:ok, current, current_placement} <- authority(worker, job_ref),
           true <- current_placement.id == placement.id,
           true <- current.worker_job_digest == request["job_digest"],
           {:ok, account} <- ModelAccounts.current(request["provider"], request["account"]),
           true <- account["epoch"] == metadata["epoch"],
           true <- worker_epoch(worker) == worker_epoch do
        save(current, placement, worker, worker_epoch, request, metadata)
      else
        _changed -> Repo.rollback(:model_grant_refused)
      end
    end)
  end

  def authorize(certificate, job_ref, provider, token) do
    with {:ok, {worker, enrolled}} <-
           fetch_authenticated_worker(certificate),
         {:ok, binding} <- authorize_worker(worker, enrolled, job_ref, provider, token) do
      {:ok, Map.put(binding, :enrollment, enrolled)}
    else
      _refused -> {:error, :model_grant_refused}
    end
  end

  # A stream has already authenticated its TLS peer. Rotation retires old
  # certificates without ending that worker's current enrollment or execution.
  def reauthorize(%{run: run, enrollment: enrolled}, job_ref, token) do
    authorize_worker(run.worker_id, enrolled, job_ref, run.provider, token)
  end

  defp fetch_authenticated_worker(certificate),
    do: Repo.fetch(Certificate.Query.active_worker_binding(Crypto.sha256_hex(certificate)))

  defp worker_epoch(worker) do
    case Repo.fetch(Worker.Query.enrolled() |> Worker.Query.by_id(worker)) do
      {:ok, current} -> current.enrollment_epoch
      _revoked -> nil
    end
  end

  defp authorize_worker(worker, enrolled, job_ref, provider, token)
       when is_binary(token) and byte_size(token) in 32..512 do
    with {:ok, run} <- Repo.fetch(ModelRun.Query.token(Crypto.sha256_hex(token))),
         true <- run.worker_id == worker and run.provider == provider,
         true <- run.worker_epoch == enrolled and worker_epoch(worker) == enrolled,
         true <- DateTime.compare(run.expires_at, Repo.now!()) == :gt,
         {:ok, session, placement} <- authority(worker, job_ref),
         true <-
           placement.id == run.placement_id and session.id == run.session_id and
             session.worker_job_digest == run.job_digest,
         true <- account_allowed?(session.worker_job_document, provider, run.account),
         {:ok, document} <- ModelAccounts.current(provider, run.account),
         true <- document["epoch"] == run.epoch do
      {:ok, %{run: run, job: session.worker_job_document, account: document}}
    else
      _refused -> {:error, :model_grant_refused}
    end
  end

  defp authorize_worker(_worker, _enrollment, _job, _provider, _token),
    do: {:error, :model_grant_refused}

  defp save(session, placement, worker, worker_epoch, request, metadata) do
    now = Repo.now!()
    expires = DateTime.add(now, @grant_seconds, :second)

    query =
      ModelRun.Query.identity(
        placement.id,
        request["run_id"],
        request["provider"],
        request["account"],
        metadata["epoch"],
        worker_epoch
      )

    run =
      case Repo.fetch(query) do
        {:ok, run} ->
          Repo.update!(ModelRun.Changeset.renew(run, expires, now))

        {:error, :not_found} ->
          id = Ecto.UUID.generate()
          token = token(id)

          attributes = %{
            id: id,
            session_id: session.id,
            placement_id: placement.id,
            worker_id: worker,
            worker_epoch: worker_epoch,
            run_id: request["run_id"],
            job_digest: request["job_digest"],
            provider: request["provider"],
            account: request["account"],
            epoch: metadata["epoch"],
            token_hash: Crypto.sha256_hex(token),
            expires_at: expires
          }

          Repo.insert!(ModelRun.Changeset.insert(attributes, now))
      end

    Map.merge(request, %{
      "token" => token(run.id),
      "epoch" => run.epoch,
      "selection" => metadata["selection"],
      "account_id" => metadata["account_id"] || "",
      "expires_at" => DateTime.to_iso8601(expires)
    })
  end

  defp token(id) do
    Config.fetch_env!(:credential_key)
    |> Crypto.hmac_sha256(["coop-model-grant-v1", <<0>>, id])
    |> Base.url_encode64(padding: false)
  end

  defp authority(worker, job_ref) do
    sessions =
      job_ref
      |> Work.Session.Query.placed_job(worker, Repo.now!())
      |> Work.Session.Query.model_execution()

    with [session] <- Repo.all(sessions),
         %{"model_credentials" => "controller"} <- session.worker_job_document,
         {:ok, digest} <- JobSpec.digest(session.worker_job_document),
         true <- digest == session.worker_job_digest,
         {:ok, placement} <-
           fetch_active_placement(session.id, worker) do
      {:ok, session, placement}
    else
      _refused -> {:error, :model_grant_refused}
    end
  end

  defp fetch_active_placement(session_id, worker) do
    session_id
    |> Placement.Query.by_session_id()
    |> Placement.Query.by_worker_id(worker)
    |> Placement.Query.active()
    |> Repo.fetch()
  end

  defp account_allowed?(job, provider, account) when is_binary(provider) and is_binary(account) do
    roles = get_in(job, ["preset", "roles"]) || []
    targets = List.wrap(job["targets"]) ++ Enum.flat_map(roles, &List.wrap(&1["targets"]))

    Enum.any?(targets, fn target ->
      String.starts_with?(target, provider <> ":") and String.ends_with?(target, "@" <> account)
    end)
  end

  defp account_allowed?(_job, _provider, _account), do: false

  defp valid_run?(value) do
    is_binary(value) and byte_size(value) in 1..128 and
      Regex.match?(~r/\A[a-zA-Z0-9_.:-]+\z/, value)
  end
end
