defmodule Ryker.Slack.AttachmentIngestorTest do
  use Ryker.DataCase, async: true
  import Ryker.TestHelpers, only: [digest: 1]
  alias Ryker.Admission.{Context, Prompt}
  alias Ryker.Artifacts
  alias Ryker.CanonicalJSON
  alias Ryker.Fixtures.SlackVoice
  alias Ryker.Fixtures.SlackVoice.Downloader
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Ingress.Input
  alias Ryker.Slack.AttachmentIngestor
  alias Ryker.TestTranscriber

  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0>>

  # Slack Connect shares a file as its id and `file_access: check_file_info`, and the ingestor
  # refused it for want of a type before files.info could say what it is (2026-10-04 review).
  test "a file shared by its id alone is looked up, then read" do
    shared = %{"file_access" => "check_file_info", "id" => "F123"}

    client = %{
      observer: self(),
      resolved: {:ok, file()},
      result: {:ok, file(), @png}
    }

    assert {:ok, enriched} =
             AttachmentIngestor.ingest(%{audience: :mention, input: input!([shared])}, %{
               client: client,
               downloader: Downloader,
               store: Artifacts
             })

    assert_received {:resolve, "F123"}
    assert_received {:download, "F123", _maximum}
    assert [%{"status" => "available", "name" => "failure.png"}] = enriched.input.content["files"]
  end

  test "downloads each eligible Slack file once and replaces private URLs with durable refs" do
    input = input!([file()])
    client = %{observer: self(), result: {:ok, file(), @png}}

    assert {:ok, enriched} =
             AttachmentIngestor.ingest(%{audience: :mention, input: input}, %{
               client: client,
               downloader: Downloader,
               store: Artifacts
             })

    assert_received {:download, "F123", 8_388_608}
    [descriptor] = enriched.input.content["files"]
    assert descriptor["status"] == "available"
    assert descriptor["artifact_ref"] =~ "artifact:input:"
    assert descriptor["sha256"] == digest(@png)
    refute Map.has_key?(descriptor, "url_private")
    refute Map.has_key?(descriptor, "url_private_download")

    assert {:ok, [artifact]} = Artifacts.fetch_many([descriptor["artifact_ref"]])
    assert artifact.data == @png

    assert {:ok, retried} =
             AttachmentIngestor.ingest(%{audience: :mention, input: input}, %{
               client: %{observer: self(), result: {:error, :must_not_download}},
               downloader: Downloader,
               store: Artifacts
             })

    refute_received {:download, "F123", _maximum}
    assert retried.input.content["files"] == enriched.input.content["files"]
  end

  # Chat reads any text file by its bytes, since a browser labels a .log or a
  # script application/octet-stream, but Slack's refused one before download
  # whenever its label was not exactly a supported type: a deploy.sh shared
  # in Slack (text/x-sh) never reached the model. The bytes decide here too.
  test "a script Slack labels by its own type is read as text, and bytes that are not text are refused" do
    script = "#!/bin/sh\nset -eu\necho deploy\n"

    shell = %{
      file()
      | "id" => "F301",
        "mimetype" => "text/x-sh",
        "name" => "deploy.sh",
        "size" => byte_size(script)
    }

    assert {:ok, enriched} =
             AttachmentIngestor.ingest(%{audience: :mention, input: input!([shell])}, %{
               client: %{observer: self(), result: {:ok, shell, script}},
               downloader: Downloader,
               store: Artifacts
             })

    assert_received {:download, "F301", _maximum}
    [descriptor] = enriched.input.content["files"]
    assert descriptor["status"] == "available"
    assert {:ok, [artifact]} = Artifacts.fetch_many([descriptor["artifact_ref"]])
    assert artifact.media_type == "text/plain"
    assert artifact.data == script

    binary = %{
      file()
      | "id" => "F302",
        "mimetype" => "application/octet-stream",
        "name" => "core.dump",
        "size" => byte_size(@png)
    }

    assert {:ok, refused} =
             AttachmentIngestor.ingest(%{audience: :mention, input: input!([binary])}, %{
               client: %{observer: self(), result: {:ok, binary, <<0, 159, 146, 150>> <> @png}},
               downloader: Downloader,
               store: Artifacts
             })

    assert [%{"reason" => "unsupported_media_type", "status" => "unavailable"}] =
             refused.input.content["files"]
  end

  test "unsafe metadata is retained as a bounded omission while transient download failure retries" do
    unsupported = %{file() | "id" => "F124", "mimetype" => "application/zip"}

    assert {:ok, enriched} =
             AttachmentIngestor.ingest(%{audience: :mention, input: input!([unsupported])}, %{
               client: %{observer: self(), result: {:error, :must_not_download}},
               downloader: Downloader,
               store: Artifacts
             })

    assert [%{"reason" => "unsupported_media_type", "status" => "unavailable"}] =
             enriched.input.content["files"]

    refute_received {:download, _id, _maximum}

    assert AttachmentIngestor.ingest(%{audience: :mention, input: input!([file()])}, %{
             client: %{observer: self(), result: {:error, {:slack_file_unavailable, :offline}}},
             downloader: Downloader,
             store: Artifacts
           }) == {:error, {:slack_file_unavailable, :offline}}
  end

  # Slack answering that a file is gone or not Ryker's to read failed the whole message;
  # Slack retried it and then dropped it, text included (2026-10-04 review). Such a file is
  # an omission the message explains, while a rate limit or an outage still retries.
  test "a file Slack will never give is an omission and the message still arrives" do
    ingest = fn failure ->
      AttachmentIngestor.ingest(%{audience: :mention, input: input!([file()])}, %{
        client: %{observer: self(), result: {:error, failure}},
        downloader: Downloader,
        store: Artifacts
      })
    end

    for failure <- [
          {:slack_file_unavailable, "file_not_found"},
          {:slack_file_unavailable, {404, ""}},
          {:slack_file_unavailable, {403, "forbidden"}}
        ] do
      assert {:ok, enriched} = ingest.(failure)

      assert [%{"reason" => "file_unavailable", "status" => "unavailable"}] =
               enriched.input.content["files"]
    end

    for failure <- [
          {:slack_file_unavailable, "ratelimited"},
          {:slack_file_unavailable, {429, ""}},
          {:slack_file_unavailable, {503, ""}}
        ] do
      assert ingest.(failure) == {:error, failure}
    end
  end

  test "file and byte limits are explicit omissions and malformed settings fail closed" do
    files = [
      %{file() | "id" => "F201", "mimetype" => "application/zip"},
      %{file() | "id" => "F202", "mimetype" => "application/zip"},
      %{file() | "id" => "F203", "mimetype" => "application/zip"}
    ]

    options = %{
      client: %{observer: self(), result: {:error, :must_not_download}},
      downloader: Downloader,
      store: Artifacts
    }

    assert {:ok, enriched} =
             AttachmentIngestor.ingest(%{audience: :mention, input: input!(files)}, options)

    assert Enum.map(enriched.input.content["files"], & &1["reason"]) == [
             "unsupported_media_type",
             "unsupported_media_type",
             "file_limit_exceeded"
           ]

    oversized = %{file() | "size" => 8_388_609}

    assert {:ok, too_large} =
             AttachmentIngestor.ingest(
               %{audience: :mention, input: input!([oversized])},
               options
             )

    assert [%{"reason" => "attachment_bytes_exceeded"}] = too_large.input.content["files"]

    assert AttachmentIngestor.ingest(:invalid, options) ==
             {:error, {:invalid_slack_attachment_ingestor, :input}}

    assert AttachmentIngestor.ingest(%{audience: :mention, input: input!([])}, %{}) ==
             {:error, {:invalid_slack_attachment_ingestor, :settings}}

    malformed_input = %{input!([]) | content: %{"files" => :invalid}}

    assert AttachmentIngestor.ingest(%{audience: :mention, input: malformed_input}, options) ==
             {:error, {:invalid_slack_attachment_ingestor, :files}}
  end

  test "permanent URL, name, and content mismatches are visible without persisting secrets" do
    cases = [
      {%{file() | "url_private" => "https://evil.test/file"},
       {:error, {:slack_file_rejected, :url}}, "invalid_url"},
      {%{file() | "name" => "../unsafe.png"}, {:ok, %{file() | "name" => "../unsafe.png"}, @png},
       "invalid_name"},
      {file(), {:ok, file(), "not-png"}, "content_mismatch"},
      {%{"id" => "bad"}, {:error, :unused}, "invalid_metadata"}
    ]

    Enum.with_index(cases, fn {metadata, result, reason}, index ->
      metadata = Map.put(metadata, "id", "F#{300 + index}")
      client = %{observer: self(), result: result}

      assert {:ok, enriched} =
               AttachmentIngestor.ingest(%{audience: :mention, input: input!([metadata])}, %{
                 client: client,
                 downloader: Downloader,
                 store: Artifacts
               })

      assert [%{"reason" => ^reason, "status" => "unavailable"}] =
               enriched.input.content["files"]
    end)
  end

  # Andrew, 2026-09-27: "I sent an audio but ryker ignored it as file not
  # available". His Slack voice message (this exact file object) was refused
  # before download because audio/mp4 was no type Ryker kept. It is kept now,
  # and its words come after Slack hears its acknowledgement: transcribing it
  # here held the Slack gateway past Slack's 3 s for any clip over about 25 s.
  test "a Slack voice message is kept with its transcript to come, and nothing transcribes it here" do
    audio = TestTranscriber.recording("Please audit the checkout service")

    assert {:ok, enriched} =
             AttachmentIngestor.ingest(
               %{audience: :direct, input: voice_input!([SlackVoice.file()])},
               SlackVoice.attachment_options({:ok, SlackVoice.file(), audio})
             )

    assert_received {:download, "F0C5LM60REC", _maximum}
    refute_received {:transcribed, _data}
    [descriptor] = enriched.input.content["files"]
    assert %{"status" => "available", "transcript_pending" => true} = descriptor
    refute Map.has_key?(descriptor, "transcript")
    assert {:ok, [artifact]} = Artifacts.fetch_many([descriptor["artifact_ref"]])
    assert {artifact.media_type, artifact.data} == {"audio/mp4", audio}

    # Slack delivers the same file again when an acknowledgement is late, and
    # in the app mention beside the message: it is not downloaded twice.
    assert {:ok, again} =
             AttachmentIngestor.ingest(
               %{audience: :direct, input: voice_input!([SlackVoice.file()])},
               SlackVoice.attachment_options({:error, :must_not_download})
             )

    assert again.input.content["files"] == enriched.input.content["files"]
    refute_received {:download, _id, _maximum}
  end

  # When Slack finished its own transcript, transcribing again would only
  # spend the seconds the Socket Mode acknowledgement is waiting on.
  test "Slack's finished transcript is used without transcribing the voice message" do
    file =
      Map.put(SlackVoice.file(), "transcription", %{
        "status" => "complete",
        "preview" => %{"content" => "Roll back the payments deploy", "has_more" => false}
      })

    audio = TestTranscriber.recording("words Ryker never hears")

    assert {:ok, enriched} =
             AttachmentIngestor.ingest(
               %{audience: :direct, input: voice_input!([file])},
               SlackVoice.attachment_options({:ok, file, audio})
             )

    routing = routing_input(enriched.input)
    assert routing =~ "Roll back the payments deploy"
    refute routing =~ "words Ryker never hears"
    refute_received {:transcribed, _data}
  end

  # Any audio Slack shares is somebody talking, even in a format Ryker does
  # not keep: routing hears that a voice message arrived that Ryker could not
  # transcribe, never just an unsupported file.
  test "a voice message in a format Ryker does not keep still reaches routing as a voice message" do
    amr = %{SlackVoice.file() | "id" => "F0C5LM60AMR", "mimetype" => "audio/amr"}

    assert {:ok, enriched} =
             AttachmentIngestor.ingest(
               %{audience: :direct, input: voice_input!([amr])},
               SlackVoice.attachment_options({:error, :must_not_download})
             )

    assert routing_input(enriched.input) =~ "a voice message Ryker could not transcribe"
    refute_received {:download, _id, _maximum}
  end

  # A voice message longer than Ryker transcribes, or larger than it keeps, is
  # refused before download; routing reads why in plain words rather than an
  # unreadable file, so the person hears what to send instead.
  test "a voice message too long or too large to transcribe is refused with a plain reason" do
    too_long = %{SlackVoice.file() | "duration_ms" => 300_001}
    too_large = %{SlackVoice.file() | "id" => "F0C5LM60REG", "size" => 8_388_609}

    for {file, reason} <- [
          {too_long, "a voice message longer than 5 minutes, the most Ryker transcribes"},
          {too_large, "a voice message larger than 8 MB, the most Ryker transcribes"}
        ] do
      assert {:ok, enriched} =
               AttachmentIngestor.ingest(
                 %{audience: :direct, input: voice_input!([file])},
                 SlackVoice.attachment_options({:error, :must_not_download})
               )

      assert [%{"transcript_unavailable" => ^reason}] = enriched.input.content["files"]
      assert routing_input(enriched.input) =~ reason
    end

    refute_received {:download, _id, _maximum}
    refute_received {:transcribed, _data}
  end

  # What routing reads of the event: its input document in the admission
  # prompt.
  defp routing_input(input) do
    %Context{
      active_episode_fingerprint: CanonicalJSON.digest([]),
      built_at: ~U[2026-09-27 09:00:01.000000Z],
      candidates: [],
      conversation_episode_count: 0,
      input: input,
      input_entry: %Entry{id: Ecto.UUID.generate()}
    }
    |> Prompt.build()
    |> get_in(["context", "input"])
    |> CanonicalJSON.encode!()
  end

  # A voice message has no text of its own.
  defp voice_input!(files), do: input!(files, "")

  defp input!(files, text \\ "Please inspect this screenshot.") do
    assert {:ok, input} =
             Input.new(%{
               actor: %{kind: :user, ref: "U123"},
               content: %{
                 "attachments" => [],
                 "blocks" => [],
                 "files" => files,
                 "slack_event_kind" => "message",
                 "subtype" => "file_share",
                 "text" => text
               },
               destination: %{
                 conversation_ref: "slack:TBEFEAD653F6D:C456",
                 thread_ref: "1787832000.000100",
                 transport: "slack"
               },
               event_kind: :message,
               event_ref: "Ev-file",
               native_input_id: "slack-message:file",
               occurred_at: ~U[2026-08-28 12:00:00.000000Z],
               occurred_at_source: :source,
               revision: 1,
               source: %{kind: "slack", ref: "TBEFEAD653F6D"},
               source_capabilities: %{"react" => %{"emoji_names" => nil}},
               source_item_ref: "1787832000.000100"
             })

    input
  end

  defp file do
    %{
      "id" => "F123",
      "mimetype" => "image/png",
      "name" => "failure.png",
      "size" => byte_size(@png),
      "url_private" => "https://files.slack.com/files-pri/TBEFEAD653F6D-F123/failure.png"
    }
  end
end
