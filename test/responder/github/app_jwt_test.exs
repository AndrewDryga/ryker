defmodule Responder.GitHub.AppJWTTest do
  use ExUnit.Case, async: true

  alias Responder.GitHub.AppJWT

  @now ~U[2026-08-29 12:00:00Z]

  test "mints the exact short-lived RS256 GitHub App claims" do
    private_key = :public_key.generate_key({:rsa, 2_048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])

    assert {:ok, signer} = AppJWT.new(12_345, pem)
    assert inspect(signer) =~ ~s(app_id: "12345")
    refute inspect(signer) =~ "RSAPrivateKey"
    assert {:ok, token} = AppJWT.token(signer, @now)
    assert [header, claims, signature] = String.split(token, ".")

    assert Jason.decode!(Base.url_decode64!(header, padding: false)) == %{
             "alg" => "RS256",
             "typ" => "JWT"
           }

    assert Jason.decode!(Base.url_decode64!(claims, padding: false)) == %{
             "exp" => DateTime.to_unix(@now) + 540,
             "iat" => DateTime.to_unix(@now) - 60,
             "iss" => "12345"
           }

    assert :public_key.verify(
             header <> "." <> claims,
             :sha256,
             Base.url_decode64!(signature, padding: false),
             private_key
           )
  end

  test "rejects malformed app identities, keys, and clocks" do
    assert AppJWT.new(0, "not-a-key") == {:error, {:invalid_github_app_jwt, :app_id}}
    assert AppJWT.new(1, "not-a-key") == {:error, {:invalid_github_app_jwt, :private_key}}

    private_key = :public_key.generate_key({:rsa, 1_024, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])
    assert {:ok, signer} = AppJWT.new("Iv1.client-id", pem)
    assert AppJWT.token(signer, :invalid) == {:error, {:invalid_github_app_jwt, :clock}}
  end
end
