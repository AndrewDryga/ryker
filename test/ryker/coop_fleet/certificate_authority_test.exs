defmodule Ryker.CoopFleet.CertificateAuthorityTest do
  use ExUnit.Case, async: true

  require Record

  alias Ryker.CoopFleet.CertificateAuthority

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

  test "one enrollment key receives a short-lived client-only certificate from the configured CA" do
    root =
      :public_key.pkix_test_root_cert(~c"Ryker Test Worker CA",
        digest: :sha256,
        key: {:rsa, 2_048, 65_537}
      )

    worker_private_key = :public_key.generate_key({:rsa, 2_048, 65_537})
    worker_public_key = {:RSAPublicKey, elem(worker_private_key, 2), elem(worker_private_key, 3)}

    public_key_pem =
      :SubjectPublicKeyInfo
      |> :public_key.pem_entry_encode(worker_public_key)
      |> then(&:public_key.pem_encode([&1]))

    ca_certificate_pem =
      :public_key.pem_encode([{:Certificate, root.cert, :not_encrypted}])

    ca_key_pem =
      :RSAPrivateKey
      |> :public_key.pem_entry_encode(root.key)
      |> then(&:public_key.pem_encode([&1]))

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, issued} =
             CertificateAuthority.issue(
               public_key_pem,
               "worker-one",
               ca_certificate_pem,
               ca_key_pem,
               now,
               3_600
             )

    certificate_time = DateTime.truncate(now, :second)

    # The live connector accepted the certificate but rejected enrollment because
    # the JSON expiry retained microseconds that an X.509 UTC time cannot encode.
    assert issued.not_before == DateTime.add(certificate_time, -60, :second)
    assert issued.expires_at == DateTime.add(certificate_time, 3_600, :second)
    assert issued.certificate_pem =~ "BEGIN CERTIFICATE"
    assert issued.sha256 == sha256(issued.certificate_der)

    assert {:ok, _details} =
             :public_key.pkix_path_validation(root.cert, [issued.certificate_der], [])

    # The legacy connector rejected every issued identity with
    # "x509: RSA key missing NULL parameters" after consuming its token.
    certificate = :public_key.pkix_decode_cert(issued.certificate_der, :otp)
    tbs_certificate = otp_certificate(certificate, :tbsCertificate)

    public_key_algorithm =
      tbs_certificate
      |> otp_tbs_certificate(:subjectPublicKeyInfo)
      |> otp_subject_public_key_info(:algorithm)

    assert public_key_algorithm(public_key_algorithm, :parameters) == :NULL

    assert signature_algorithm(otp_tbs_certificate(tbs_certificate, :signature), :parameters) ==
             {:asn1_OPENTYPE, <<5, 0>>}
  end

  test "the certificate authority accepts an OpenSSL PKCS8 private key" do
    # The live gateway accepted this standard key at boot, but worker enrollment
    # returned HTTP 400 before it could issue an identity certificate.
    root =
      :public_key.pkix_test_root_cert(~c"Ryker Test Worker CA",
        digest: :sha256,
        key: {:rsa, 2_048, 65_537}
      )

    ca_certificate_pem =
      :public_key.pem_encode([{:Certificate, root.cert, :not_encrypted}])

    ca_key_pem =
      :PrivateKeyInfo
      |> :public_key.pem_entry_encode(root.key)
      |> then(&:public_key.pem_encode([&1]))

    assert ca_key_pem =~ "BEGIN PRIVATE KEY"

    assert {:ok, _issued} =
             CertificateAuthority.issue(
               public_key_pem(private_key()),
               "worker-pkcs8",
               ca_certificate_pem,
               ca_key_pem,
               ~U[2026-08-29 12:00:00.000000Z],
               3_600
             )
  end

  test "weak worker keys and private-key submissions are rejected" do
    root =
      :public_key.pkix_test_root_cert(~c"Ryker Test Worker CA",
        digest: :sha256,
        key: {:rsa, 2_048, 65_537}
      )

    ca_certificate_pem =
      :public_key.pem_encode([{:Certificate, root.cert, :not_encrypted}])

    ca_key_pem =
      :RSAPrivateKey
      |> :public_key.pem_entry_encode(root.key)
      |> then(&:public_key.pem_encode([&1]))

    weak_key = :public_key.generate_key({:rsa, 1_024, 65_537})
    weak_public = {:RSAPublicKey, elem(weak_key, 2), elem(weak_key, 3)}

    weak_public_pem =
      :SubjectPublicKeyInfo
      |> :public_key.pem_entry_encode(weak_public)
      |> then(&:public_key.pem_encode([&1]))

    private_pem =
      :RSAPrivateKey
      |> :public_key.pem_entry_encode(weak_key)
      |> then(&:public_key.pem_encode([&1]))

    assert {:error, :coop_worker_public_key_too_small} =
             CertificateAuthority.issue(
               weak_public_pem,
               "worker-one",
               ca_certificate_pem,
               ca_key_pem,
               ~U[2026-08-29 12:00:00.000000Z],
               3_600
             )

    assert {:error, :invalid_coop_worker_public_key} =
             CertificateAuthority.issue(
               private_pem,
               "worker-one",
               ca_certificate_pem,
               ca_key_pem,
               ~U[2026-08-29 12:00:00.000000Z],
               3_600
             )
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp private_key, do: :public_key.generate_key({:rsa, 2_048, 65_537})

  defp public_key_pem(private_key) do
    public_key = {:RSAPublicKey, elem(private_key, 2), elem(private_key, 3)}

    :SubjectPublicKeyInfo
    |> :public_key.pem_entry_encode(public_key)
    |> then(&:public_key.pem_encode([&1]))
  end
end
