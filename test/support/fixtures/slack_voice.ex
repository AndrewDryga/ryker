defmodule Ryker.Fixtures.SlackVoice do
  @moduledoc false

  # A Slack voice message as Socket Mode delivers it, around the file object
  # Slack sent for Andrew's voice message on 2026-09-27.

  defmodule Downloader do
    @moduledoc false

    # Serves what Slack would have, and tells the test each download it made.
    def download(%{observer: observer, result: result}, file, maximum_bytes) do
      send(observer, {:download, file["id"], maximum_bytes})
      result
    end

    # What files.info says of a file a message named only by its id.
    def resolve(%{observer: observer} = client, file) do
      send(observer, {:resolve, file["id"]})
      Map.get(client, :resolved, {:ok, file})
    end
  end

  @workspace_ref "T74CADB5B58F9"

  def file do
    %{
      "id" => "F0C5LM60REC",
      "name" => "audio_message.m4a",
      "mimetype" => "audio/mp4",
      "filetype" => "m4a",
      "subtype" => "slack_audio",
      "media_display_type" => "audio",
      "size" => 109_145,
      "duration_ms" => 6680,
      "mode" => "hosted",
      "file_access" => "visible",
      "transcription" => %{"status" => "none"}
    }
  end

  @doc "A direct message to Ryker that is only a voice message."
  def envelope(event_ref, overrides \\ []) do
    ts = Keyword.get(overrides, :ts, "1790500000.000100")

    %{
      "envelope_id" => "env-" <> event_ref,
      "payload" => %{
        "event" => %{
          "channel" => Keyword.get(overrides, :channel_ref, "D0VOICE"),
          "channel_type" => "im",
          "event_ts" => ts,
          "files" => [Keyword.get(overrides, :file, file())],
          "subtype" => "file_share",
          "text" => "",
          "ts" => ts,
          "type" => "message",
          "user" => "U123"
        },
        "event_id" => event_ref,
        "event_time" => 1_790_500_000,
        "team_id" => Keyword.get(overrides, :workspace_ref, @workspace_ref),
        "type" => "event_callback"
      },
      "type" => "events_api"
    }
  end

  @doc "The attachment settings the Slack runtime gives the gateway, with Slack's download faked."
  def attachment_options(result) do
    %{
      client: %{observer: self(), result: result},
      downloader: Downloader,
      store: Ryker.Artifacts
    }
  end
end
