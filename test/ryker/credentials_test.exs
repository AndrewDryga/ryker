defmodule Ryker.CredentialsTest do
  use Ryker.DataCase, async: false
  import Ecto.Query
  alias Ryker.Config
  alias Ryker.Credential
  alias Ryker.Credential.Event
  alias Ryker.Credentials

  @actor "control-plane:test"
  @secret "xoxb-super-secret-value-that-must-never-render"

  setup do
    Config.put_override(:credential_key, :binary.copy(<<21>>, 32))
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

    assert Credentials.delete(:slack_bot, "primary", @actor) == :ok
    assert Credentials.fetch(:slack_bot, "primary") == {:error, :credential_missing}
    assert %{status: :missing} = Credentials.status(:slack_bot, "primary")
  end

  test "wrong keys, ciphertext tampering and record relocation fail closed" do
    assert {:ok, _metadata} = Credentials.put(:emisar, "primary", @secret, @actor)

    Config.put_override(:credential_key, :binary.copy(<<22>>, 32))
    assert Credentials.fetch(:emisar, "primary") == {:error, :credential_decryption_failed}
    Config.put_override(:credential_key, :binary.copy(<<21>>, 32))

    from(credential in Credential,
      where: credential.kind == :emisar and credential.name == "primary"
    )
    |> Repo.update_all(set: [ciphertext: <<0, 1, 2, 3>>])

    assert Credentials.fetch(:emisar, "primary") == {:error, :credential_decryption_failed}

    assert {:ok, _metadata} = Credentials.put(:github_webhook, "primary", @secret, @actor)

    from(credential in Credential,
      where: credential.kind == :github_webhook and credential.name == "primary"
    )
    |> Repo.update_all(set: [name: "relocated"])

    assert Credentials.fetch(:github_webhook, "relocated") ==
             {:error, :credential_decryption_failed}
  end

  # Every stored secret is redaction material too: worker output is scanned
  # for it before anyone sees it, and the worker server refuses a secret under
  # eight bytes, which cannot be told apart from ordinary text. One stored
  # five-character secret therefore stopped every later settings apply.
  test "a secret too short to redact from worker output is never stored" do
    assert Credentials.put(:webhook, "grafana", "short", @actor) ==
             {:error, :credential_value_too_short}

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

  # 2026-10-04 review: the fingerprint was a plain SHA-256 of the secret, stored beside the
  # ciphertext, so anyone holding a database dump or backup could check a guessed secret
  # against it offline, and two credentials holding one value showed it. It is keyed by the
  # credential root and bound to the credential's identity; the same value saved again keeps it.
  test "a fingerprint lets no one with the database check a guessed secret" do
    assert {:ok, _metadata} = Credentials.put(:webhook, "alerts", @secret, @actor)
    assert {:ok, _metadata} = Credentials.put(:webhook, "deploys", @secret, @actor)

    alerts = Credentials.status(:webhook, "alerts")
    deploys = Credentials.status(:webhook, "deploys")

    refute alerts.fingerprint == Ryker.Crypto.sha256_hex(@secret)
    refute alerts.fingerprint == deploys.fingerprint

    assert {:ok, _metadata} = Credentials.put(:webhook, "alerts", @secret, @actor)
    assert Credentials.status(:webhook, "alerts").fingerprint == alerts.fingerprint

    Config.put_override(:credential_key, :binary.copy(<<23>>, 32))
    assert {:ok, _metadata} = Credentials.put(:webhook, "rotated", @secret, @actor)
    refute Credentials.status(:webhook, "rotated").fingerprint == alerts.fingerprint
  end

  # 2026-10-04 review: a credential that no longer decrypted, after a key change, dropped out
  # of redaction without a word, so its value could reach worker output and examples unmasked.
  test "a credential redaction cannot read is named in the log" do
    assert {:ok, _metadata} = Credentials.put(:webhook, "alerts", @secret, @actor)
    Config.put_override(:credential_key, :binary.copy(<<22>>, 32))

    log =
      ExUnit.CaptureLog.capture_log(fn -> assert Credentials.redaction_values() == [] end)

    assert log =~ "webhook/alerts"
    assert log =~ "not redacted"
    refute log =~ @secret
  end

  # Removing a credential that was never saved changed nothing, yet announced
  # a change, and the runtime reassembled every lane for it (2026-10-04
  # review).
  test "removing a credential that is not saved changes nothing and announces nothing" do
    assert Credentials.subscribe() == :ok

    result = Credentials.delete(:webhook, "never-saved", @actor)

    refute_receive {:credentials_changed, :webhook, "never-saved"}, 100
    assert Repo.all(Event) == []
    assert result == :ok
  end

  test "a committed credential change tells the runtime to reassemble" do
    assert Credentials.subscribe() == :ok

    assert {:ok, _metadata} = Credentials.put(:slack_bot, "primary", @secret, @actor)
    assert_receive {:credentials_changed, :slack_bot, "primary"}

    assert Credentials.delete(:slack_bot, "primary", @actor) == :ok
    assert_receive {:credentials_changed, :slack_bot, "primary"}

    assert Credentials.put(:unknown, "primary", @secret, @actor) ==
             {:error, :credential_identity_invalid}

    refute_receive {:credentials_changed, :unknown, "primary"}
  end
end
