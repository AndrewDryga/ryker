defmodule Ryker.CredentialsTest do
  use Ryker.DataCase, async: false

  import Ecto.Query

  alias Ryker.Credential
  alias Ryker.Credential.Event
  alias Ryker.Credentials

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

    assert :ok = Credentials.delete(:slack_bot, "primary", @actor)
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

  # Every stored secret is redaction material too: worker output is scanned
  # for it before anyone sees it, and the worker server refuses a secret under
  # eight bytes, which cannot be told apart from ordinary text. One stored
  # five-character secret therefore stopped every later settings apply.
  test "a secret too short to redact from worker output is never stored" do
    assert {:error, :credential_value_too_short} =
             Credentials.put(:webhook, "grafana", "short", @actor)

    assert Credentials.fetch(:webhook, "grafana") == {:error, :credential_missing}
    assert {:ok, _metadata} = Credentials.put(:webhook, "grafana", "eight-ch", @actor)
  end

  test "inspection lists status metadata but no secret bytes" do
    assert {:ok, _metadata} = Credentials.put(:webhook, "alerts", @secret, @actor)

    assert [status] = Credentials.statuses()
    assert status.name == "alerts"
    assert status.fingerprint =~ ~r/\A[0-9a-f]{64}\z/
    refute inspect(status) =~ @secret
  end

  # Removing a credential that was never saved changed nothing, yet announced
  # a change, and the runtime reassembled every lane for it (2026-10-04
  # review).
  test "removing a credential that is not saved changes nothing and announces nothing" do
    assert :ok = Credentials.subscribe()

    result = Credentials.delete(:webhook, "never-saved", @actor)

    refute_receive {:credentials_changed, :webhook, "never-saved"}, 100
    assert Repo.all(Event) == []
    assert result == :ok
  end

  test "a committed credential change tells the runtime to reassemble" do
    assert :ok = Credentials.subscribe()

    assert {:ok, _metadata} = Credentials.put(:slack_bot, "primary", @secret, @actor)
    assert_receive {:credentials_changed, :slack_bot, "primary"}

    assert :ok = Credentials.delete(:slack_bot, "primary", @actor)
    assert_receive {:credentials_changed, :slack_bot, "primary"}

    assert {:error, :credential_identity_invalid} =
             Credentials.put(:unknown, "primary", @secret, @actor)

    refute_receive {:credentials_changed, :unknown, "primary"}
  end
end
