defmodule Ryker.CoopFleet.CertificateAuthority do
  @moduledoc false

  require Record

  Record.defrecordp(
    :otp_certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :otp_tbs_certificate,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :otp_subject_public_key_info,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :public_key_algorithm,
    :PublicKeyAlgorithm,
    Record.extract(:PublicKeyAlgorithm, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :signature_algorithm,
    :SignatureAlgorithm,
    Record.extract(:SignatureAlgorithm, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :attribute_type_and_value,
    :AttributeTypeAndValue,
    Record.extract(:AttributeTypeAndValue, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :validity,
    :Validity,
    Record.extract(:Validity, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :extension,
    :Extension,
    Record.extract(:Extension, from_lib: "public_key/include/public_key.hrl")
  )

  Record.defrecordp(
    :rsa_public_key,
    :RSAPublicKey,
    Record.extract(:RSAPublicKey, from_lib: "public_key/include/public_key.hrl")
  )

  @rsa_encryption {1, 2, 840, 113_549, 1, 1, 1}
  @sha256_with_rsa {1, 2, 840, 113_549, 1, 1, 11}
  @common_name {2, 5, 4, 3}
  @organization_name {2, 5, 4, 10}
  @key_usage {2, 5, 29, 15}
  @extended_key_usage {2, 5, 29, 37}
  @client_auth {1, 3, 6, 1, 5, 5, 7, 3, 2}
  @minimum_rsa_bits 2_048
  @maximum_public_key_bytes 16 * 1_024
  @asn1_null :NULL
  @der_null {:asn1_OPENTYPE, <<5, 0>>}

  @type issued :: %{
          certificate_der: binary(),
          certificate_pem: binary(),
          expires_at: DateTime.t(),
          not_before: DateTime.t(),
          serial_number: String.t(),
          sha256: String.t()
        }

  @spec issue(String.t(), String.t(), String.t(), String.t(), DateTime.t(), pos_integer()) ::
          {:ok, issued()} | {:error, term()}
  def issue(public_key_pem, worker_id, ca_certificate_pem, ca_key_pem, now, ttl_seconds)
      when is_binary(public_key_pem) and is_binary(worker_id) and
             is_binary(ca_certificate_pem) and is_binary(ca_key_pem) and
             is_struct(now, DateTime) and is_integer(ttl_seconds) and ttl_seconds > 0 do
    with :ok <- public_key_size(public_key_pem),
         {:ok, public_key} <- decode_public_key(public_key_pem),
         :ok <- rsa_strength(public_key),
         {:ok, ca_certificate_der} <- pem_der(ca_certificate_pem, :Certificate),
         {:ok, ca_key} <- pem_value(ca_key_pem, :RSAPrivateKey),
         {:ok, certificate_der, serial_number, not_before, expires_at} <-
           sign(public_key, worker_id, ca_certificate_der, ca_key, now, ttl_seconds) do
      sha256 = :crypto.hash(:sha256, certificate_der) |> Base.encode16(case: :lower)

      {:ok,
       %{
         certificate_der: certificate_der,
         certificate_pem:
           :public_key.pem_encode([{:Certificate, certificate_der, :not_encrypted}]),
         expires_at: expires_at,
         not_before: not_before,
         serial_number: serial_number,
         sha256: sha256
       }}
    end
  rescue
    _error -> {:error, :invalid_coop_worker_certificate_request}
  end

  def issue(_public_key_pem, _worker_id, _ca_certificate_pem, _ca_key_pem, _now, _ttl),
    do: {:error, :invalid_coop_worker_certificate_request}

  defp sign(public_key, worker_id, ca_certificate_der, ca_key, now, ttl_seconds) do
    ca_certificate = :public_key.pkix_decode_cert(ca_certificate_der, :otp)
    issuer = ca_certificate |> otp_certificate(:tbsCertificate) |> otp_tbs_certificate(:subject)
    not_before = now |> DateTime.add(-60, :second) |> normalize()
    expires_at = now |> DateTime.add(ttl_seconds, :second) |> normalize()
    serial_integer = :crypto.strong_rand_bytes(16) |> :binary.decode_unsigned()
    serial_number = Integer.to_string(serial_integer)

    signature =
      signature_algorithm(algorithm: @sha256_with_rsa, parameters: @der_null)

    subject_public_key_info =
      otp_subject_public_key_info(
        algorithm: public_key_algorithm(algorithm: @rsa_encryption, parameters: @asn1_null),
        subjectPublicKey: public_key
      )

    subject =
      {:rdnSequence,
       [
         [
           attribute_type_and_value(
             type: @organization_name,
             value: {:utf8String, ~c"Ryker Coop Workers"}
           )
         ],
         [
           attribute_type_and_value(
             type: @common_name,
             value: {:utf8String, String.to_charlist(worker_id)}
           )
         ]
       ]}

    certificate =
      otp_tbs_certificate(
        version: :v3,
        serialNumber: serial_integer,
        signature: signature,
        issuer: issuer,
        validity:
          validity(
            notBefore: asn1_time(not_before),
            notAfter: asn1_time(expires_at)
          ),
        subject: subject,
        subjectPublicKeyInfo: subject_public_key_info,
        extensions: [
          extension(extnID: @key_usage, critical: true, extnValue: [:digitalSignature]),
          extension(extnID: @extended_key_usage, critical: false, extnValue: [@client_auth])
        ]
      )

    {:ok, :public_key.pkix_sign(certificate, ca_key), serial_number, not_before, expires_at}
  end

  defp decode_public_key(pem) do
    with {:ok, value} <- pem_value(pem, :SubjectPublicKeyInfo),
         true <- Record.is_record(value, :RSAPublicKey) do
      {:ok, value}
    else
      _invalid -> {:error, :invalid_coop_worker_public_key}
    end
  end

  defp rsa_strength(public_key) do
    modulus = rsa_public_key(public_key, :modulus)

    if bit_size(:binary.encode_unsigned(modulus)) >= @minimum_rsa_bits,
      do: :ok,
      else: {:error, :coop_worker_public_key_too_small}
  end

  defp pem_der(pem, expected_type) do
    case :public_key.pem_decode(pem) do
      [{^expected_type, der, :not_encrypted}] when is_binary(der) -> {:ok, der}
      _invalid -> {:error, :invalid_coop_worker_certificate_authority}
    end
  end

  defp pem_value(pem, expected_type) do
    case :public_key.pem_decode(pem) do
      [{^expected_type, _der, :not_encrypted} = entry] ->
        {:ok, :public_key.pem_entry_decode(entry)}

      [{:PrivateKeyInfo, _der, :not_encrypted} = entry]
      when expected_type == :RSAPrivateKey ->
        case :public_key.pem_entry_decode(entry) do
          value when is_tuple(value) and elem(value, 0) == :RSAPrivateKey -> {:ok, value}
          _invalid -> {:error, :invalid_coop_worker_pem}
        end

      _invalid ->
        {:error, :invalid_coop_worker_pem}
    end
  end

  defp public_key_size(value) when byte_size(value) <= @maximum_public_key_bytes, do: :ok
  defp public_key_size(_value), do: {:error, :coop_worker_public_key_too_large}

  defp asn1_time(datetime) do
    year = datetime.year
    suffix = Calendar.strftime(datetime, "%m%d%H%M%SZ") |> String.to_charlist()

    if year < 2_050 do
      {:utcTime, String.to_charlist(Integer.to_string(year) |> String.slice(2, 2)) ++ suffix}
    else
      {:generalTime, String.to_charlist(Integer.to_string(year)) ++ suffix}
    end
  end

  defp normalize(%DateTime{} = datetime), do: DateTime.truncate(datetime, :second)
end
