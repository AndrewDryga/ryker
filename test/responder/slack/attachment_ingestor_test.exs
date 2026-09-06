defmodule Responder.Slack.AttachmentIngestorTest do
  use Responder.DataCase, async: true

  alias Responder.Artifacts
  alias Responder.Ingress.Input
  alias Responder.Slack.AttachmentIngestor

  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0>>

  defmodule Downloader do
    def download(%{observer: observer, result: result}, file, maximum_bytes) do
      send(observer, {:download, file["id"], maximum_bytes})
      result
    end
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

  defp input!(files) do
    assert {:ok, input} =
             Input.new(%{
               actor: %{kind: :user, ref: "U123"},
               content: %{
                 "attachments" => [],
                 "blocks" => [],
                 "files" => files,
                 "slack_event_kind" => "message",
                 "subtype" => "file_share",
                 "text" => "Please inspect this screenshot."
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

  defp digest(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end
