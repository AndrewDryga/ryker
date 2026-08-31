defmodule Responder.CoopFleet.EnrollmentTest do
  use Responder.DataCase, async: true

  alias Responder.CoopFleet.{Certificate, ControlPlane, Enrollment, EnrollmentToken}

  test "a single-use token binds one named worker without receiving its private key" do
    authority = authority()

    assert {:ok, issued_token} =
             Enrollment.issue_token("worker-enroll", "workspace-main", "operator:andrew", 300)

    private_key = private_key()

    assert {:ok, enrolled} =
             Enrollment.enroll(
               %{
                 "public_key_pem" => public_key_pem(private_key),
                 "token" => issued_token.token,
                 "worker_id" => "worker-enroll",
                 "workspace_ref" => "workspace-main"
               },
               authority
             )

    assert enrolled["worker_id"] == "worker-enroll"
    assert enrolled["workspace_ref"] == "workspace-main"
    assert enrolled["certificate_pem"] =~ "BEGIN CERTIFICATE"
    refute Map.has_key?(enrolled, "private_key_pem")

    token = Repo.get!(EnrollmentToken, issued_token.id)
    assert token.consumed_at
    assert token.certificate_sha256 == enrolled["certificate_sha256"]
    assert Repo.get!(Certificate, enrolled["certificate_sha256"]).source == :enrollment

    assert {:ok, "worker-enroll"} =
             enrolled["certificate_pem"]
             |> certificate_der()
             |> ControlPlane.authenticate_certificate()

    assert {:error, :coop_worker_enrollment_token_consumed} =
             Enrollment.enroll(
               %{
                 "public_key_pem" => public_key_pem(private_key()),
                 "token" => issued_token.token,
                 "worker_id" => "worker-enroll",
                 "workspace_ref" => "workspace-main"
               },
               authority
             )
  end

  test "certificate renewal overlaps old and new identities so a lost response cannot strand the worker" do
    authority = authority()

    assert {:ok, issued_token} =
             Enrollment.issue_token("worker-rotate", "workspace-main", "operator:andrew", 300)

    assert {:ok, enrolled} =
             Enrollment.enroll(
               %{
                 "public_key_pem" => public_key_pem(private_key()),
                 "token" => issued_token.token,
                 "worker_id" => "worker-rotate",
                 "workspace_ref" => "workspace-main"
               },
               authority
             )

    old_der = certificate_der(enrolled["certificate_pem"])

    assert {:ok, renewed} =
             Enrollment.renew(
               old_der,
               %{"public_key_pem" => public_key_pem(private_key())},
               authority
             )

    new_der = certificate_der(renewed["certificate_pem"])
    refute renewed["certificate_sha256"] == enrolled["certificate_sha256"]
    assert {:ok, "worker-rotate"} = ControlPlane.authenticate_certificate(old_der)
    assert {:ok, "worker-rotate"} = ControlPlane.authenticate_certificate(new_der)
    assert Repo.aggregate(Certificate, :count) == 2
  end

  test "a token cannot be redirected to another worker or workspace" do
    authority = authority()

    assert {:ok, issued_token} =
             Enrollment.issue_token("worker-bound", "workspace-bound", "operator:andrew", 300)

    request = %{
      "public_key_pem" => public_key_pem(private_key()),
      "token" => issued_token.token,
      "worker_id" => "worker-other",
      "workspace_ref" => "workspace-bound"
    }

    assert {:error, :coop_worker_enrollment_not_authorized} =
             Enrollment.enroll(request, authority)

    refute Repo.get!(EnrollmentToken, issued_token.id).consumed_at
    assert Repo.aggregate(Certificate, :count) == 0
  end

  test "enrollment authority request and TTL inputs fail closed before certificate custody" do
    authority = authority()

    assert {:error, {:invalid_coop_worker_enrollment, :worker_id}} =
             Enrollment.issue_token("bad worker", "workspace", "operator", 60)

    assert {:error, :invalid_coop_worker_enrollment_token_ttl} =
             Enrollment.issue_token("worker", "workspace", "operator", 0)

    assert {:error, :invalid_coop_worker_enrollment} = Enrollment.enroll([], authority)

    for document <- [
          %{},
          %{
            "public_key_pem" => public_key_pem(private_key()),
            "token" => "short",
            "worker_id" => "worker",
            "workspace_ref" => "workspace"
          },
          %{
            "public_key_pem" => nil,
            "token" => String.duplicate("t", 32),
            "worker_id" => "worker",
            "workspace_ref" => "workspace"
          }
        ] do
      assert {:error, :invalid_coop_worker_enrollment} = Enrollment.enroll(document, authority)
    end

    valid_document = %{
      "public_key_pem" => public_key_pem(private_key()),
      "token" => String.duplicate("t", 32),
      "worker_id" => "worker",
      "workspace_ref" => "workspace"
    }

    assert {:error, :invalid_coop_worker_certificate_authority} =
             Enrollment.enroll(valid_document, nil)

    assert {:error, :invalid_coop_worker_certificate_ttl} =
             Enrollment.enroll(valid_document, %{authority | certificate_ttl_seconds: 1})

    assert {:error, :authority} = Enrollment.enroll(valid_document, [:not_a_keyword])
    assert {:error, :enoent} = Enrollment.enroll(valid_document, cacertfile: "/missing/ca")

    assert {:error, :invalid_coop_worker_renewal} = Enrollment.renew(:invalid, %{}, authority)

    assert {:error, :invalid_coop_worker_renewal} =
             Enrollment.renew("certificate", %{}, authority)

    assert {:error, :coop_worker_certificate_not_authorized} =
             Enrollment.renew(
               "unknown-certificate",
               %{"public_key_pem" => public_key_pem(private_key())},
               authority
             )
  end

  defp authority do
    root =
      :public_key.pkix_test_root_cert(~c"Responder Test Worker CA",
        digest: :sha256,
        key: {:rsa, 2_048, 65_537}
      )

    %{
      ca_certificate_pem: :public_key.pem_encode([{:Certificate, root.cert, :not_encrypted}]),
      ca_key_pem:
        :RSAPrivateKey
        |> :public_key.pem_entry_encode(root.key)
        |> then(&:public_key.pem_encode([&1])),
      certificate_ttl_seconds: 3_600
    }
  end

  defp private_key, do: :public_key.generate_key({:rsa, 2_048, 65_537})

  defp public_key_pem(private_key) do
    public_key = {:RSAPublicKey, elem(private_key, 2), elem(private_key, 3)}

    :SubjectPublicKeyInfo
    |> :public_key.pem_entry_encode(public_key)
    |> then(&:public_key.pem_encode([&1]))
  end

  defp certificate_der(pem) do
    [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(pem)
    der
  end
end
