defmodule Responder.CoopFleet.CertificateAuthorityTest do
  use ExUnit.Case, async: true

  alias Responder.CoopFleet.CertificateAuthority

  test "one enrollment key receives a short-lived client-only certificate from the configured CA" do
    root =
      :public_key.pkix_test_root_cert(~c"Responder Test Worker CA",
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

    assert issued.not_before == DateTime.add(now, -60, :second)
    assert issued.expires_at == DateTime.add(now, 3_600, :second)
    assert issued.certificate_pem =~ "BEGIN CERTIFICATE"
    assert issued.sha256 == sha256(issued.certificate_der)

    assert {:ok, _details} =
             :public_key.pkix_path_validation(root.cert, [issued.certificate_der], [])
  end

  test "weak worker keys and private-key submissions are rejected" do
    root =
      :public_key.pkix_test_root_cert(~c"Responder Test Worker CA",
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
end
