defmodule Ryker.CoopFleet.Enrollment do
  @moduledoc """
  Single-use bootstrap and overlapping client-certificate rotation for Coop workers.

  Tokens are operator-minted, stored only as SHA-256 digests, scoped to one
  worker/workspace pair, and consumed in the same transaction that binds the
  issued certificate. Worker private keys never cross the gateway.
  """

  import Ecto.Changeset
  import Ecto.Query

  alias Ryker.CoopFleet.{Certificate, CertificateAuthority, EnrollmentToken, Worker}
  alias Ryker.Repo

  @reference ~r/\A[A-Za-z0-9_.:-]+\z/
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
      token = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
      token_sha256 = sha256(token)

      transaction(fn ->
        now = database_now!()
        ensure_worker_enrollable!(worker_id)

        enrollment =
          %EnrollmentToken{}
          |> cast(
            %{
              expires_at: DateTime.add(now, ttl_seconds, :second),
              operator_ref: operator_ref,
              token_sha256: token_sha256,
              worker_id: worker_id,
              workspace_ref: workspace_ref
            },
            [:expires_at, :operator_ref, :token_sha256, :worker_id, :workspace_ref]
          )
          |> validate_required([
            :expires_at,
            :operator_ref,
            :token_sha256,
            :worker_id,
            :workspace_ref
          ])
          |> unique_constraint(:token_sha256)
          |> check_constraint(:worker_id, name: :coop_worker_enrollment_token_valid)
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
      transaction(fn -> enroll_locked(request, signer) end)
    end
  end

  @spec renew(binary(), map(), map() | keyword()) :: {:ok, map()} | {:error, term()}
  def renew(certificate_der, document, authority)
      when is_binary(certificate_der) and is_map(document) do
    with {:ok, request} <- renewal_request(document),
         {:ok, signer} <- authority(authority) do
      certificate_sha256 = sha256(certificate_der)
      transaction(fn -> renew_locked(certificate_sha256, request, signer) end)
    end
  end

  def renew(_certificate_der, _document, _authority),
    do: {:error, :invalid_coop_worker_renewal}

  defp enroll_locked(request, signer) do
    now = database_now!()
    token_sha256 = sha256(request.token)

    token =
      Repo.one(
        from(token in EnrollmentToken,
          where: token.token_sha256 == ^token_sha256,
          lock: "FOR UPDATE"
        )
      ) || rollback(:coop_worker_enrollment_not_authorized)

    ensure_token_usable!(token, request, now)
    issued = issue_certificate!(request.public_key_pem, request.worker_id, signer, now)
    worker = upsert_enrolled_worker!(request.worker_id, request.workspace_ref, issued.sha256)
    insert_certificate!(worker.id, token.id, issued, :enrollment, token.operator_ref)

    token
    |> change(%{certificate_sha256: issued.sha256, consumed_at: now})
    |> check_constraint(:certificate_sha256, name: :coop_worker_enrollment_token_valid)
    |> Repo.update()
    |> unwrap_write()

    response(worker, issued, signer.ca_certificate_pem)
  end

  defp renew_locked(certificate_sha256, request, signer) do
    now = database_now!()

    certificate =
      Repo.one(
        from(certificate in Certificate,
          where: certificate.sha256 == ^certificate_sha256,
          lock: "FOR UPDATE"
        )
      ) || rollback(:coop_worker_certificate_not_authorized)

    if certificate.revoked_at || DateTime.compare(certificate.not_before, now) == :gt ||
         DateTime.compare(certificate.expires_at, now) != :gt,
       do: rollback(:coop_worker_certificate_not_authorized)

    worker = locked_worker!(certificate.worker_id)

    if worker.state == :revoked,
      do: rollback(:coop_worker_certificate_not_authorized)

    issued = issue_certificate!(request.public_key_pem, worker.id, signer, now)
    insert_certificate!(worker.id, nil, issued, :renewal, "worker:#{worker.id}")

    worker =
      worker
      |> change(%{certificate_sha256: issued.sha256})
      |> unique_constraint(:certificate_sha256)
      |> Repo.update()
      |> unwrap_write()

    response(worker, issued, signer.ca_certificate_pem)
  end

  defp ensure_token_usable!(token, request, now) do
    cond do
      token.consumed_at ->
        rollback(:coop_worker_enrollment_token_consumed)

      DateTime.compare(token.expires_at, now) != :gt ->
        rollback(:coop_worker_enrollment_token_expired)

      token.worker_id != request.worker_id ->
        rollback(:coop_worker_enrollment_not_authorized)

      token.workspace_ref != request.workspace_ref ->
        rollback(:coop_worker_enrollment_not_authorized)

      true ->
        :ok
    end
  end

  defp ensure_worker_enrollable!(worker_id) do
    case Repo.one(from(worker in Worker, where: worker.id == ^worker_id, lock: "FOR UPDATE")) do
      %Worker{state: :revoked} -> rollback(:coop_worker_enrollment_not_authorized)
      %Worker{} -> :ok
      nil -> :ok
    end
  end

  defp upsert_enrolled_worker!(worker_id, workspace_ref, certificate_sha256) do
    case Repo.one(from(worker in Worker, where: worker.id == ^worker_id, lock: "FOR UPDATE")) do
      nil ->
        %Worker{}
        |> cast(
          %{
            certificate_sha256: certificate_sha256,
            id: worker_id,
            state: :offline,
            workspace_ref: workspace_ref
          },
          [:certificate_sha256, :id, :state, :workspace_ref]
        )
        |> validate_required([:certificate_sha256, :id, :state, :workspace_ref])
        |> unique_constraint(:certificate_sha256)
        |> check_constraint(:id, name: :coop_worker_identity_valid)
        |> Repo.insert()
        |> unwrap_write()

      %Worker{workspace_ref: ^workspace_ref, state: state} = worker when state != :revoked ->
        worker
        |> change(%{certificate_sha256: certificate_sha256})
        |> unique_constraint(:certificate_sha256)
        |> Repo.update()
        |> unwrap_write()

      %Worker{} ->
        rollback(:coop_worker_enrollment_not_authorized)
    end
  end

  defp insert_certificate!(worker_id, token_id, issued, source, issued_by) do
    %Certificate{}
    |> cast(
      %{
        enrollment_token_id: token_id,
        expires_at: issued.expires_at,
        issued_by: issued_by,
        not_before: issued.not_before,
        serial_number: issued.serial_number,
        sha256: issued.sha256,
        source: source,
        worker_id: worker_id
      },
      [
        :enrollment_token_id,
        :expires_at,
        :issued_by,
        :not_before,
        :serial_number,
        :sha256,
        :source,
        :worker_id
      ]
    )
    |> validate_required([
      :expires_at,
      :issued_by,
      :not_before,
      :serial_number,
      :sha256,
      :source,
      :worker_id
    ])
    |> foreign_key_constraint(:worker_id)
    |> foreign_key_constraint(:enrollment_token_id)
    |> check_constraint(:sha256, name: :coop_worker_certificate_valid)
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

  defp enrollment_request(%{} = document) do
    if Map.keys(document) |> Enum.sort() ==
         ~w(public_key_pem token worker_id workspace_ref) do
      with :ok <- reference(document["worker_id"], :worker_id),
           :ok <- reference(document["workspace_ref"], :workspace_ref),
           :ok <- token(document["token"]),
           :ok <- public_key_pem(document["public_key_pem"]) do
        {:ok,
         %{
           public_key_pem: document["public_key_pem"],
           token: document["token"],
           worker_id: document["worker_id"],
           workspace_ref: document["workspace_ref"]
         }}
      end
    else
      {:error, :invalid_coop_worker_enrollment}
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
    Repo.one(from(worker in Worker, where: worker.id == ^worker_id, lock: "FOR UPDATE")) ||
      rollback(:coop_worker_certificate_not_authorized)
  end

  defp token(value) when is_binary(value) and byte_size(value) in 32..128 do
    if String.valid?(value), do: :ok, else: {:error, :invalid_coop_worker_enrollment}
  end

  defp token(_value), do: {:error, :invalid_coop_worker_enrollment}

  defp public_key_pem(value) when is_binary(value) and byte_size(value) in 1..16_384,
    do: :ok

  defp public_key_pem(_value), do: {:error, :invalid_coop_worker_enrollment}

  defp reference(value, field)
       when is_binary(value) and byte_size(value) in 1..256 do
    if String.valid?(value) and Regex.match?(@reference, value),
      do: :ok,
      else: {:error, {:invalid_coop_worker_enrollment, field}}
  end

  defp reference(_value, field), do: {:error, {:invalid_coop_worker_enrollment, field}}

  defp token_ttl(value)
       when is_integer(value) and value in 1..@maximum_token_ttl_seconds,
       do: :ok

  defp token_ttl(_value), do: {:error, :invalid_coop_worker_enrollment_token_ttl}

  defp certificate_ttl(value)
       when is_integer(value) and value in 300..@maximum_certificate_ttl_seconds,
       do: :ok

  defp certificate_ttl(_value), do: {:error, :invalid_coop_worker_certificate_ttl}

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp database_now! do
    %{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp unwrap_write({:ok, value}), do: value

  defp unwrap_write({:error, changeset}),
    do: rollback({:coop_worker_enrollment_store_error, changeset})

  defp rollback(reason), do: Repo.rollback(reason)
end
