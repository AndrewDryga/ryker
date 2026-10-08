defmodule Ryker.CoopFleet.EnrollmentTest do
  use Ryker.DataCase, async: true
  alias Ryker.CoopFleet.{Certificate, ControlPlane, Enrollment, EnrollmentToken}

  test "a single-use token binds one named worker without receiving its private key" do
    authority = authority()

    assert {:ok, issued_token} =
             Enrollment.issue_token("worker-enroll", "workspace-main", "operator:andrew", 300)

    private_key = private_key()

    assert {:ok, enrolled} =
             Enrollment.enroll(
               %{
                 "public_key_pem" => public_key_pem(private_key),
                 "token" => issued_token.token
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

    assert enrolled["certificate_pem"]
           |> certificate_der()
           |> ControlPlane.authenticate_certificate() == {:ok, "worker-enroll"}

    assert Enrollment.enroll(
             %{
               "public_key_pem" => public_key_pem(private_key()),
               "token" => issued_token.token
             },
             authority
           ) == {:error, :coop_worker_enrollment_token_consumed}
  end

  test "a fresh worker learns its identity and workspace from the token alone" do
    assert {:ok, issued_token} =
             Enrollment.issue_token(
               "worker-token-only",
               "workspace-remote",
               "operator:andrew",
               300
             )

    request = %{
      "public_key_pem" => public_key_pem(private_key()),
      "token" => issued_token.token
    }

    assert {:ok, enrolled} = Enrollment.enroll(request, authority())
    assert enrolled["worker_id"] == "worker-token-only"
    assert enrolled["workspace_ref"] == "workspace-remote"
    assert enrolled["ca_certificate_pem"] =~ "BEGIN CERTIFICATE"
    assert Repo.get!(EnrollmentToken, issued_token.id).consumed_at

    assert Enrollment.enroll(request, authority()) ==
             {:error, :coop_worker_enrollment_token_consumed}
  end

  test "certificate renewal overlaps old and new identities so a lost response cannot strand the worker" do
    authority = authority()

    assert {:ok, issued_token} =
             Enrollment.issue_token("worker-rotate", "workspace-main", "operator:andrew", 300)

    assert {:ok, enrolled} =
             Enrollment.enroll(
               %{
                 "public_key_pem" => public_key_pem(private_key()),
                 "token" => issued_token.token
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
    assert ControlPlane.authenticate_certificate(old_der) == {:ok, "worker-rotate"}
    assert ControlPlane.authenticate_certificate(new_der) == {:ok, "worker-rotate"}
    assert Repo.aggregate(Certificate, :count) == 2
  end

  # Enrolling again left every earlier certificate valid until it expired, up
  # to a week, and any of them could renew itself meanwhile (2026-10-04 review).
  test "enrolling a worker again cuts off every certificate it had" do
    authority = authority()
    first = enroll!("worker-reenrolled", authority)

    assert {:ok, renewed} =
             Enrollment.renew(
               certificate_der(first["certificate_pem"]),
               %{"public_key_pem" => public_key_pem(private_key())},
               authority
             )

    again = enroll!("worker-reenrolled", authority)

    for earlier <- [first, renewed] do
      assert earlier["certificate_pem"]
             |> certificate_der()
             |> ControlPlane.authenticate_certificate() ==
               {:error, :coop_worker_certificate_not_authorized}
    end

    assert again["certificate_pem"]
           |> certificate_der()
           |> ControlPlane.authenticate_certificate() == {:ok, "worker-reenrolled"}
  end

  test "a renewal leaves valid only the certificate that asked and the new one" do
    authority = authority()
    enrolled = enroll!("worker-renewals", authority)
    first = certificate_der(enrolled["certificate_pem"])

    renew = &Enrollment.renew(&1, %{"public_key_pem" => public_key_pem(private_key())}, authority)

    assert {:ok, lost} = renew.(first)
    # The answer was lost, so the worker asks again with the certificate it has.
    assert {:ok, second} = renew.(first)
    second = certificate_der(second["certificate_pem"])

    assert lost["certificate_pem"]
           |> certificate_der()
           |> ControlPlane.authenticate_certificate() ==
             {:error, :coop_worker_certificate_not_authorized}

    assert {:ok, third} = renew.(second)

    assert ControlPlane.authenticate_certificate(first) ==
             {:error, :coop_worker_certificate_not_authorized}

    assert ControlPlane.authenticate_certificate(second) == {:ok, "worker-renewals"}

    assert third["certificate_pem"]
           |> certificate_der()
           |> ControlPlane.authenticate_certificate() == {:ok, "worker-renewals"}

    # A certificate cut off this way cannot renew either.
    assert renew.(first) == {:error, :coop_worker_certificate_not_authorized}
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

    assert Enrollment.enroll(request, authority) == {:error, :invalid_coop_worker_enrollment}

    refute Repo.get!(EnrollmentToken, issued_token.id).consumed_at
    assert Repo.aggregate(Certificate, :count) == 0
  end

  test "enrollment authority request and TTL inputs fail closed before certificate custody" do
    authority = authority()

    assert Enrollment.issue_token("bad worker", "workspace", "operator", 60) ==
             {:error, {:invalid_coop_worker_enrollment, :worker_id}}

    assert Enrollment.issue_token("worker", "workspace", "operator", 0) ==
             {:error, :invalid_coop_worker_enrollment_token_ttl}

    assert Enrollment.enroll([], authority) == {:error, :invalid_coop_worker_enrollment}

    for document <- [
          %{},
          %{
            "public_key_pem" => public_key_pem(private_key()),
            "token" => "short"
          },
          %{
            "public_key_pem" => nil,
            "token" => String.duplicate("t", 32)
          }
        ] do
      assert Enrollment.enroll(document, authority) == {:error, :invalid_coop_worker_enrollment}
    end

    valid_document = %{
      "public_key_pem" => public_key_pem(private_key()),
      "token" => String.duplicate("t", 32)
    }

    assert Enrollment.enroll(valid_document, nil) ==
             {:error, :invalid_coop_worker_certificate_authority}

    assert Enrollment.enroll(valid_document, %{authority | certificate_ttl_seconds: 1}) ==
             {:error, :invalid_coop_worker_certificate_ttl}

    assert Enrollment.enroll(valid_document, [:not_a_keyword]) == {:error, :authority}
    assert Enrollment.enroll(valid_document, cacertfile: "/missing/ca") == {:error, :enoent}

    assert Enrollment.renew(:invalid, %{}, authority) == {:error, :invalid_coop_worker_renewal}

    assert Enrollment.renew("certificate", %{}, authority) ==
             {:error, :invalid_coop_worker_renewal}

    assert Enrollment.renew(
             "unknown-certificate",
             %{"public_key_pem" => public_key_pem(private_key())},
             authority
           ) == {:error, :coop_worker_certificate_not_authorized}
  end

  defp enroll!(worker_id, authority) do
    assert {:ok, issued} =
             Enrollment.issue_token(worker_id, "workspace-main", "operator:andrew", 300)

    assert {:ok, enrolled} =
             Enrollment.enroll(
               %{"public_key_pem" => public_key_pem(private_key()), "token" => issued.token},
               authority
             )

    enrolled
  end

  defp authority do
    root =
      :public_key.pkix_test_root_cert(~c"Ryker Test Worker CA",
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
