defmodule Ryker.GitHubActions.SignInMigrationTest do
  use Ryker.MigrationCase
  alias Ecto.Adapters.SQL

  @before 20_261_109_195_500
  @version 20_261_117_180_000

  test "adding user sign-in keeps existing credentials and permits encrypted OAuth secrets" do
    in_scratch_schema("github_action_sign_in", fn repo, prefix ->
      migrate!(repo, prefix, @before)
      insert_credential(repo, prefix, "github_webhook")
      assert @version in migrate!(repo, prefix, @version)
      insert_credential(repo, prefix, "github_oauth_secret")

      assert %{rows: [["github_oauth_secret"], ["github_webhook"]]} =
               SQL.query!(
                 repo,
                 "SELECT kind FROM #{prefix}.integration_credentials ORDER BY kind"
               )

      assert_raise Postgrex.Error, ~r/integration_credentials_valid/, fn ->
        insert_credential(repo, prefix, "unknown_kind")
      end
    end)
  end

  defp insert_credential(repo, prefix, kind) do
    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.integration_credentials
        (id, kind, name, key_version, ciphertext, nonce, tag, verification_status, inserted_at, updated_at)
      VALUES ($1, $2, 'primary', 1, $3, $4, $5, 'unverified', now(), now())
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        kind,
        <<1>>,
        :binary.copy(<<2>>, 12),
        :binary.copy(<<3>>, 16)
      ]
    )
  end
end
