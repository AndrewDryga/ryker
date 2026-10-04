defmodule Ryker.Artifacts.KeepVoiceMessagesMigrationTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL

  defmodule MigrationRepo do
    use Ecto.Repo,
      otp_app: :ryker,
      adapter: Ecto.Adapters.Postgres
  end

  @before_version 20_260_927_110_000
  @version 20_260_927_140_000
  @at ~N[2026-09-27 09:00:00.000000]

  # Andrew's Slack voice message (2026-09-27) was refused before download:
  # an input artifact could not be audio, so routing read an unavailable file
  # and ignored him. A kept voice message is what a person said; rolling back
  # to a release with no room for it must refuse rather than lose it.
  test "a voice message can be kept, and rolling back never loses one" do
    repo = start_migration_repo!()
    prefix = "keep_voice_messages_#{System.unique_integer([:positive])}"
    SQL.query!(repo, "CREATE SCHEMA #{prefix}", [])

    try do
      Ecto.Migrator.run(repo, Ryker.TestMigrations.all(), :up,
        to: @before_version,
        prefix: prefix,
        log: false
      )

      assert_raise Postgrex.Error, ~r/input_artifact_identity_valid/, fn ->
        artifact!(repo, prefix, "audio/mp4")
      end

      assert @version in Ecto.Migrator.run(repo, Ryker.TestMigrations.all(), :up,
               to: @version,
               prefix: prefix,
               log: false
             )

      artifact!(repo, prefix, "text/plain")
      artifact!(repo, prefix, "audio/mp4")
      artifact!(repo, prefix, "video/quicktime")

      assert_raise Postgrex.Error, ~r/input_artifact_identity_valid/, fn ->
        artifact!(repo, prefix, "audio/amr")
      end

      assert_raise Postgrex.Error, ~r/nowhere to keep them/, fn ->
        Ecto.Migrator.run(repo, Ryker.TestMigrations.all(), :down,
          step: 1,
          prefix: prefix,
          log: false
        )
      end

      assert media_types(repo, prefix) == ["audio/mp4", "text/plain", "video/quicktime"]

      SQL.query!(
        repo,
        "DELETE FROM #{prefix}.input_artifacts WHERE media_type <> 'text/plain'",
        []
      )

      assert Ecto.Migrator.run(repo, Ryker.TestMigrations.all(), :down,
               step: 1,
               prefix: prefix,
               log: false
             ) ==
               [@version]

      assert media_types(repo, prefix) == ["text/plain"]

      assert_raise Postgrex.Error, ~r/input_artifact_identity_valid/, fn ->
        artifact!(repo, prefix, "audio/mp4")
      end
    after
      SQL.query!(repo, "DROP SCHEMA IF EXISTS #{prefix} CASCADE", [])
    end
  end

  defp artifact!(repo, prefix, media_type) do
    data = "recording bytes for #{media_type}"
    sha256 = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)

    SQL.query!(
      repo,
      """
      INSERT INTO #{prefix}.input_artifacts
        (id, ref, source_kind, source_ref, name, media_type, sha256, byte_size, data,
         inserted_at, updated_at)
      VALUES ($1, $2, 'slack', $3, 'audio_message.m4a', $4, $5, $6, $7, $8, $8)
      """,
      [
        Ecto.UUID.dump!(Ecto.UUID.generate()),
        "artifact:input:#{String.slice(sha256, 0, 16)}",
        "T1:#{media_type}",
        media_type,
        sha256,
        byte_size(data),
        data,
        @at
      ]
    )
  end

  defp media_types(repo, prefix) do
    %{rows: rows} =
      SQL.query!(
        repo,
        "SELECT media_type FROM #{prefix}.input_artifacts ORDER BY media_type",
        []
      )

    List.flatten(rows)
  end

  defp start_migration_repo! do
    config =
      Ryker.Repo.config()
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 2)

    start_supervised!({MigrationRepo, config})
    MigrationRepo
  end
end
