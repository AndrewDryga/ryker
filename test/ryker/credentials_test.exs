defmodule Ryker.CredentialsTest do
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.Credentials
  alias Ryker.Credentials.{Credential, Event}

  @actor "control-plane:test"
  @secret "xoxb-super-secret-value-that-must-never-render"

  setup do
    previous = Application.fetch_env!(:ryker, :credential_key)
    Application.put_env(:ryker, :credential_key, :binary.copy(<<21>>, 32))
    on_exit(fn -> Application.put_env(:ryker, :credential_key, previous) end)
  end

  test "credentials round trip, replace and delete without exposing plaintext" do
    assert {:ok, created} = Credentials.put(:slack_bot, "primary", @secret, @actor)
    assert created.status == :configured
    assert created.verification_status == :unverified
    refute inspect(created) =~ @secret
    assert {:ok, @secret} = Credentials.fetch(:slack_bot, "primary")

    assert {:ok, verified} = Credentials.verify(:slack_bot, "primary", :verified, @actor)
    assert verified.verification_status == :verified
    assert %DateTime{} = verified.verified_at

    replacement = "xoxb-replacement-secret-value"
    assert {:ok, replaced} = Credentials.put(:slack_bot, "primary", replacement, @actor)
    assert replaced.verification_status == :unverified
    assert {:ok, ^replacement} = Credentials.fetch(:slack_bot, "primary")

    row = Repo.get_by!(Credential, kind: :slack_bot, name: "primary")
    refute inspect(row) =~ @secret
    refute inspect(row) =~ replacement
    refute inspect(Repo.all(Event)) =~ @secret
    refute inspect(Repo.all(Event)) =~ replacement

    assert {:ok, :ok} = Credentials.delete(:slack_bot, "primary", @actor)
    assert {:error, :credential_missing} = Credentials.fetch(:slack_bot, "primary")
    assert %{status: :missing} = Credentials.status(:slack_bot, "primary")
  end

  test "wrong keys, ciphertext tampering and record relocation fail closed" do
    assert {:ok, _metadata} = Credentials.put(:emisar, "primary", @secret, @actor)

    Application.put_env(:ryker, :credential_key, :binary.copy(<<22>>, 32))
    assert {:error, :credential_decryption_failed} = Credentials.fetch(:emisar, "primary")
    Application.put_env(:ryker, :credential_key, :binary.copy(<<21>>, 32))

    from(credential in Credential,
      where: credential.kind == :emisar and credential.name == "primary"
    )
    |> Repo.update_all(set: [ciphertext: <<0, 1, 2, 3>>])

    assert {:error, :credential_decryption_failed} = Credentials.fetch(:emisar, "primary")

    assert {:ok, _metadata} = Credentials.put(:github_webhook, "primary", @secret, @actor)

    from(credential in Credential,
      where: credential.kind == :github_webhook and credential.name == "primary"
    )
    |> Repo.update_all(set: [name: "relocated"])

    assert {:error, :credential_decryption_failed} =
             Credentials.fetch(:github_webhook, "relocated")
  end

  test "inspection lists status metadata but no secret bytes" do
    assert {:ok, _metadata} = Credentials.put(:webhook, "alerts", @secret, @actor)

    assert [status] = Credentials.statuses()
    assert status.name == "alerts"
    assert status.fingerprint =~ ~r/\A[0-9a-f]{64}\z/
    refute inspect(status) =~ @secret
  end

  test "a committed credential change tells the runtime to reassemble" do
    assert :ok = Credentials.subscribe()

    assert {:ok, _metadata} = Credentials.put(:slack_bot, "primary", @secret, @actor)
    assert_receive {:credentials_changed, :slack_bot, "primary"}

    assert {:ok, :ok} = Credentials.delete(:slack_bot, "primary", @actor)
    assert_receive {:credentials_changed, :slack_bot, "primary"}

    assert {:error, :credential_identity_invalid} =
             Credentials.put(:unknown, "primary", @secret, @actor)

    refute_receive {:credentials_changed, :unknown, "primary"}
  end
end
