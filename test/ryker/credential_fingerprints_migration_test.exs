defmodule Ryker.CredentialFingerprintsMigrationTest do
  # A credential's fingerprint was a plain SHA-256 of its secret, so a dump or a backup let
  # anyone check a guessed secret offline (2026-10-04 review). The migration clears the plain
  # ones from the credentials and their history and keeps the history's rows; the next save
  # writes a keyed fingerprint (`Ryker.CredentialsTest`).
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL
  alias Ryker.Crypto

  @before_version 20_261_007_140_000
  @version 20_261_007_150_000
  @secret "webhook-secret-from-before-the-migration"

  test "plain fingerprints are cleared and the history keeps its rows" do
    in_scratch_schema("plain_fingerprints", fn repo, prefix ->
      migrate!(repo, prefix, @before_version)
      plain = Crypto.sha256_hex(@secret)
      id = Ecto.UUID.generate()

      SQL.query!(
        repo,
        """
        INSERT INTO #{prefix}.integration_credentials
          (id, kind, name, key_version, ciphertext, nonce, tag, fingerprint,
           verification_status, inserted_at, updated_at)
        VALUES ($1, 'webhook', 'alerts', 1, $2, $3, $4, $5, 'unverified', now(), now())
        """,
        [Ecto.UUID.dump!(id), <<1>>, :binary.copy(<<2>>, 12), :binary.copy(<<3>>, 16), plain]
      )

      SQL.query!(
        repo,
        """
        INSERT INTO #{prefix}.integration_credential_events
          (id, credential_id, kind, name, action, actor_ref, fingerprint, inserted_at)
        VALUES ($1, $2, 'webhook', 'alerts', 'created', 'control-plane:test', $3, now())
        """,
        [Ecto.UUID.dump!(Ecto.UUID.generate()), Ecto.UUID.dump!(id), plain]
      )

      assert @version in migrate!(repo, prefix, @version)

      assert %{rows: [[nil]]} =
               SQL.query!(repo, "SELECT fingerprint FROM #{prefix}.integration_credentials")

      assert %{rows: [[1, 0]]} =
               SQL.query!(
                 repo,
                 "SELECT count(*), count(fingerprint) FROM #{prefix}.integration_credential_events"
               )

      # A keyed fingerprint still has to look like one.
      assert_raise Postgrex.Error, ~r/integration_credentials_valid/, fn ->
        SQL.query!(
          repo,
          "UPDATE #{prefix}.integration_credentials SET fingerprint = 'not-a-digest'"
        )
      end
    end)
  end
end
