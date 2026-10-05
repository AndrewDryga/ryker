defmodule Ryker.Artifacts.KeepVoiceMessagesMigrationTest do
  use Ryker.MigrationCase

  import Ryker.TestHelpers, only: [digest: 1]

  alias Ecto.Adapters.SQL

  @before_version 20_260_927_110_000
  @version 20_260_927_140_000
  @at ~N[2026-09-27 09:00:00.000000]

  # Andrew's Slack voice message (2026-09-27) was refused before download:
  # an input artifact could not be audio, so routing read an unavailable file
  # and ignored him. A kept voice message is what a person said; rolling back
  # to a release with no room for it must refuse rather than lose it.
  test "a voice message can be kept, and rolling back never loses one" do
    in_scratch_schema("keep_voice_messages", fn repo, prefix ->
      migrate!(repo, prefix, @before_version)

      assert_raise Postgrex.Error, ~r/input_artifact_identity_valid/, fn ->
        artifact!(repo, prefix, "audio/mp4")
      end

      assert @version in migrate!(repo, prefix, @version)

      artifact!(repo, prefix, "text/plain")
      artifact!(repo, prefix, "audio/mp4")
      artifact!(repo, prefix, "video/quicktime")

      assert_raise Postgrex.Error, ~r/input_artifact_identity_valid/, fn ->
        artifact!(repo, prefix, "audio/amr")
      end

      assert_raise Postgrex.Error, ~r/nowhere to keep them/, fn ->
        rollback!(repo, prefix)
      end

      assert media_types(repo, prefix) == ["audio/mp4", "text/plain", "video/quicktime"]

      SQL.query!(
        repo,
        "DELETE FROM #{prefix}.input_artifacts WHERE media_type <> 'text/plain'",
        []
      )

      assert rollback!(repo, prefix) ==
               [@version]

      assert media_types(repo, prefix) == ["text/plain"]

      assert_raise Postgrex.Error, ~r/input_artifact_identity_valid/, fn ->
        artifact!(repo, prefix, "audio/mp4")
      end
    end)
  end

  defp artifact!(repo, prefix, media_type) do
    data = "recording bytes for #{media_type}"
    sha256 = digest(data)

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
end
