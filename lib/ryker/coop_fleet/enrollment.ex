defmodule Ryker.CoopFleet.Enrollment do
  @moduledoc """
  Single-use bootstrap and overlapping client-certificate rotation for Coop workers.

  Tokens are operator-minted, stored only as SHA-256 digests, scoped to one
  worker/workspace pair, and consumed in the same transaction that binds the
  issued certificate. Worker private keys never cross the gateway.
  """

  alias Ryker.CoopFleet.{Certificate, CertificateAuthority}
  alias Ryker.CoopFleet.EnrollmentToken
  alias Ryker.CoopFleet.{Protocol, Worker}
  alias Ryker.Crypto
  alias Ryker.Repo

  @maximum_token_ttl_seconds 3_600
  @maximum_certificate_ttl_seconds 7 * 24 * 60 * 60
  @default_token_ttl_seconds 15 * 60
  @default_certificate_ttl_seconds 24 * 60 * 60

  @spec issue_token(String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, map()} | {:error, term()}
  def issue_token(
        worker_id,
        workspace_ref,
        operator_ref,
        ttl_seconds \\ @default_token_ttl_seconds
      ) do
    with :ok <- reference(worker_id, :worker_id),
         :ok <- reference(workspace_ref, :workspace_ref),
         :ok <- reference(operator_ref, :operator_ref),
         :ok <- token_ttl(ttl_seconds) do
      token = Crypto.random_secret(32)
      token_sha256 = Crypto.sha256_hex(token)

      Repo.transaction(fn ->
        now = Repo.now!()
        ensure_worker_enrollable!(worker_id)

        enrollment =
          %{
            expires_at: DateTime.add(now, ttl_seconds, :second),
            operator_ref: operator_ref,
            token_sha256: token_sha256,
            worker_id: worker_id,
            workspace_ref: workspace_ref
          }
          |> EnrollmentToken.Changeset.insert()
          |> Repo.insert()
          |> unwrap_write()

        %{
          expires_at: enrollment.expires_at,
          id: enrollment.id,
          token: token,
          worker_id: worker_id,
          workspace_ref: workspace_ref
        }
      end)
    end
  end

  @spec enroll(map(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def enroll(document, authority) do
    with {:ok, request} <- enrollment_request(document),
         {:ok, signer} <- authority(authority) do
      Repo.transaction(fn -> enroll_locked(request, signer) end)
    end
  end

  @spec renew(binary(), map(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def renew(certificate_der, document, authority)
      when is_binary(certificate_der) and is_map(document) do
    with {:ok, request} <- renewal_request(document),
         {:ok, signer} <- authority(authority) do
      certificate_sha256 = Crypto.sha256_hex(certificate_der)
      Repo.transaction(fn -> renew_locked(certificate_sha256, request, signer) end)
    end
  end

  def renew(_certificate_der, _document, _authority),
    do: {:error, :invalid_coop_worker_renewal}

  defp enroll_locked(request, signer) do
    now = Repo.now!()
    token_sha256 = Crypto.sha256_hex(request.token)

    token =
      token_sha256
      |> EnrollmentToken.Query.by_digest()
      |> EnrollmentToken.Query.lock_for_update()
      |> Repo.one() || rollback(:coop_worker_enrollment_not_authorized)

    ensure_token_usable!(token, now)
    issued = issue_certificate!(request.public_key_pem, token.worker_id, signer, now)
    worker = upsert_enrolled_worker!(token.worker_id, token.workspace_ref, issued.sha256)
    insert_certificate!(worker.id, token.id, issued, :enrollment, token.operator_ref)
    # Enrolling again replaces the worker's identity, so the certificates it
    # had stop working now; they stayed valid until they expired, up to a week
    # (2026-10-04 review).
    revoke_others!(worker.id, [issued.sha256], now, token.operator_ref)

    token
    |> EnrollmentToken.Changeset.consume(issued.sha256, now)
    |> Repo.update()
    |> unwrap_write()

    response(worker, issued, signer.ca_certificate_pem)
  end

  defp renew_locked(certificate_sha256, request, signer) do
    now = Repo.now!()

    certificate =
      certificate_sha256
      |> Certificate.Query.by_sha256()
      |> Certificate.Query.lock_for_update()
      |> Repo.one() || rollback(:coop_worker_certificate_not_authorized)

    if certificate.revoked_at || DateTime.compare(certificate.not_before, now) == :gt ||
         DateTime.compare(certificate.expires_at, now) != :gt,
       do: rollback(:coop_worker_certificate_not_authorized)

    worker = locked_worker!(certificate.worker_id)

    if worker.state == :revoked,
      do: rollback(:coop_worker_certificate_not_authorized)

    issued = issue_certificate!(request.public_key_pem, worker.id, signer, now)
    insert_certificate!(worker.id, nil, issued, :renewal, "worker:#{worker.id}")
    # The certificate that asked stays valid beside the new one, so a lost
    # answer cannot strand the worker. Every other one stops: each copy of an
    # older key could otherwise renew itself for as long as it lived
    # (2026-10-04 review).
    revoke_others!(worker.id, [issued.sha256, certificate.sha256], now, "worker:#{worker.id}")

    worker =
      worker
      |> Worker.Changeset.bind_certificate(issued.sha256)
      |> Repo.update()
      |> unwrap_write()

    response(worker, issued, signer.ca_certificate_pem)
  end

  defp revoke_others!(worker_id, kept, now, revoked_by) do
    worker_id
    |> Certificate.Query.by_worker_id()
    |> Certificate.Query.unrevoked()
    |> Certificate.Query.excluding_sha256s(kept)
    |> Repo.update_all(set: [revoked_at: now, revoked_by: revoked_by])

    :ok
  end

  defp ensure_token_usable!(token, now) do
    cond do
      token.consumed_at ->
        rollback(:coop_worker_enrollment_token_consumed)

      DateTime.compare(token.expires_at, now) != :gt ->
        rollback(:coop_worker_enrollment_token_expired)

      true ->
        :ok
    end
  end

  defp ensure_worker_enrollable!(worker_id) do
    case locked_worker(worker_id) do
      %Worker{state: :revoked} -> rollback(:coop_worker_enrollment_not_authorized)
      %Worker{} -> :ok
      nil -> :ok
    end
  end

  defp upsert_enrolled_worker!(worker_id, workspace_ref, certificate_sha256) do
    case locked_worker(worker_id) do
      nil ->
        %{
          certificate_sha256: certificate_sha256,
          id: worker_id,
          state: :offline,
          workspace_ref: workspace_ref
        }
        |> Worker.Changeset.insert()
        |> Repo.insert()
        |> unwrap_write()

      %Worker{workspace_ref: ^workspace_ref, state: state} = worker when state != :revoked ->
        worker
        |> Worker.Changeset.bind_certificate(certificate_sha256)
        |> Repo.update()
        |> unwrap_write()

      %Worker{} ->
        rollback(:coop_worker_enrollment_not_authorized)
    end
  end

  defp insert_certificate!(worker_id, token_id, issued, source, issued_by) do
    %{
      enrollment_token_id: token_id,
      expires_at: issued.expires_at,
      issued_by: issued_by,
      not_before: issued.not_before,
      serial_number: issued.serial_number,
      sha256: issued.sha256,
      source: source,
      worker_id: worker_id
    }
    |> Certificate.Changeset.insert()
    |> Repo.insert()
    |> unwrap_write()
  end

  defp issue_certificate!(public_key_pem, worker_id, signer, now) do
    case CertificateAuthority.issue(
           public_key_pem,
           worker_id,
           signer.ca_certificate_pem,
           signer.ca_key_pem,
           now,
           signer.certificate_ttl_seconds
         ) do
      {:ok, issued} -> issued
      {:error, reason} -> rollback(reason)
    end
  end

  defp response(worker, issued, ca_certificate_pem) do
    %{
      "ca_certificate_pem" => ca_certificate_pem,
      "certificate_expires_at" => DateTime.to_iso8601(issued.expires_at),
      "certificate_pem" => issued.certificate_pem,
      "certificate_sha256" => issued.sha256,
      "worker_id" => worker.id,
      "workspace_ref" => worker.workspace_ref
    }
  end

  defp enrollment_request(%{"public_key_pem" => key, "token" => value} = document)
       when map_size(document) == 2 do
    with :ok <- token(value),
         :ok <- public_key_pem(key) do
      {:ok, %{public_key_pem: key, token: value}}
    end
  end

  defp enrollment_request(_document), do: {:error, :invalid_coop_worker_enrollment}

  defp renewal_request(%{"public_key_pem" => public_key_pem} = document)
       when map_size(document) == 1 do
    with :ok <- public_key_pem(public_key_pem), do: {:ok, %{public_key_pem: public_key_pem}}
  end

  defp renewal_request(_document), do: {:error, :invalid_coop_worker_renewal}

  defp authority(configuration) when is_list(configuration) do
    if Keyword.keyword?(configuration),
      do: authority(Map.new(configuration)),
      else: {:error, :authority}
  end

  defp authority(%{} = configuration) do
    ttl = Map.get(configuration, :certificate_ttl_seconds, @default_certificate_ttl_seconds)

    with :ok <- certificate_ttl(ttl),
         {:ok, ca_certificate_pem} <-
           authority_pem(configuration, :ca_certificate_pem, :cacertfile),
         {:ok, ca_key_pem} <- authority_pem(configuration, :ca_key_pem, :ca_keyfile) do
      {:ok,
       %{
         ca_certificate_pem: ca_certificate_pem,
         ca_key_pem: ca_key_pem,
         certificate_ttl_seconds: ttl
       }}
    end
  end

  defp authority(_configuration), do: {:error, :invalid_coop_worker_certificate_authority}

  defp authority_pem(configuration, pem_key, file_key) do
    case {Map.get(configuration, pem_key), Map.get(configuration, file_key)} do
      {pem, nil} when is_binary(pem) and byte_size(pem) > 0 -> {:ok, pem}
      {nil, path} when is_binary(path) -> File.read(path)
      _invalid -> {:error, :invalid_coop_worker_certificate_authority}
    end
  end

  defp locked_worker!(worker_id) do
    locked_worker(worker_id) || rollback(:coop_worker_certificate_not_authorized)
  end

  defp token(value) when is_binary(value) and byte_size(value) in 32..128 do
    if String.valid?(value), do: :ok, else: {:error, :invalid_coop_worker_enrollment}
  end

  defp token(_value), do: {:error, :invalid_coop_worker_enrollment}

  defp public_key_pem(value) when is_binary(value) and byte_size(value) in 1..16_384,
    do: :ok

  defp public_key_pem(_value), do: {:error, :invalid_coop_worker_enrollment}

  defp reference(value, field) do
    if Protocol.reference?(value),
      do: :ok,
      else: {:error, {:invalid_coop_worker_enrollment, field}}
  end

  defp token_ttl(value)
       when is_integer(value) and value in 1..@maximum_token_ttl_seconds,
       do: :ok

  defp token_ttl(_value), do: {:error, :invalid_coop_worker_enrollment_token_ttl}

  defp certificate_ttl(value)
       when is_integer(value) and value in 300..@maximum_certificate_ttl_seconds,
       do: :ok

  defp certificate_ttl(_value), do: {:error, :invalid_coop_worker_certificate_ttl}

  defp unwrap_write({:ok, value}), do: value

  defp unwrap_write({:error, changeset}),
    do: rollback({:coop_worker_enrollment_store_error, changeset})

  defp rollback(reason), do: Repo.rollback(reason)

  defp locked_worker(worker_id),
    do: worker_id |> Worker.Query.by_id() |> Worker.Query.lock_for_update() |> Repo.one()
end
