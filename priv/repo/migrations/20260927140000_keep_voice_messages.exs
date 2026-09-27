defmodule Ryker.Repo.Migrations.KeepVoiceMessages do
  use Ecto.Migration

  # Andrew, 2026-09-27: a voice message sent to Ryker in Slack was refused
  # before download because its type (audio/mp4) was not one an input
  # artifact could hold, and routing ignored "an unavailable file with no
  # text". Voice messages and videos are now kept as input artifacts and reach
  # the models as their transcript (`Ryker.Transcription`); Coop still never
  # receives their bytes.
  #
  # Rolling back refuses while any recording is kept: the previous release's
  # check has no room for one, and deleting it would lose what a person sent.

  @previous ~w(
    image/png image/jpeg image/webp image/gif text/plain text/markdown text/csv
    application/json application/yaml application/x-yaml application/pdf
  )
  @recordings ~w(
    audio/aac audio/mp4 audio/mpeg audio/ogg audio/wav audio/webm
    video/mp4 video/quicktime video/webm
  )

  def up do
    drop(constraint(:input_artifacts, :input_artifact_identity_valid))

    create(
      constraint(:input_artifacts, :input_artifact_identity_valid,
        check: identity(@previous ++ @recordings)
      )
    )
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM #{qualified("input_artifacts")}
        WHERE media_type IN (#{quoted(@recordings)})
      ) THEN
        RAISE EXCEPTION 'voice messages or videos are kept as input artifacts; the previous release has nowhere to keep them';
      END IF;
    END
    $$
    """)

    drop(constraint(:input_artifacts, :input_artifact_identity_valid))

    create(
      constraint(:input_artifacts, :input_artifact_identity_valid, check: identity(@previous))
    )
  end

  defp identity(media_types) do
    """
    char_length(ref) BETWEEN 1 AND 128
    AND source_kind ~ '^[a-z0-9_.-]+$'
    AND char_length(source_kind) BETWEEN 1 AND 64
    AND char_length(source_ref) BETWEEN 1 AND 1024
    AND char_length(name) BETWEEN 1 AND 255
    AND media_type IN (#{quoted(media_types)})
    AND sha256 ~ '^[0-9a-f]{64}$'
    AND byte_size BETWEEN 1 AND 8388608
    AND octet_length(data) = byte_size
    """
  end

  defp quoted(values), do: Enum.map_join(values, ", ", &"'#{&1}'")

  defp qualified(name) do
    schema = prefix() || "public"
    ~s("#{String.replace(schema, "\"", "\"\"")}"."#{name}")
  end
end
