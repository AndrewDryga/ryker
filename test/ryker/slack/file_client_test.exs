defmodule Ryker.Slack.FileClientTest do
  use ExUnit.Case, async: true

  alias Ryker.Slack.FileClient

  defmodule JSONRequester do
    def request(response, :get, "/files.info?file=F123", nil, []), do: response
  end

  defmodule BinaryRequester do
    def get({observer, response}, url, maximum_bytes) do
      send(observer, {:downloaded, url, maximum_bytes})
      response
    end
  end

  test "resolves a delayed Slack file and downloads only from Slack's secure file host" do
    json_response =
      {:ok,
       %{
         body: %{
           "file" => %{
             "id" => "F123",
             "mimetype" => "image/png",
             "name" => "failure.png",
             "size" => 12,
             "url_private_download" =>
               "https://edgeapi.files.slack.com/files-pri/T123-F123/failure.png"
           },
           "ok" => true
         },
         status: 200
       }}

    assert {:ok, client} =
             FileClient.new(%{
               binary_http: {self(), {:ok, %{body: "png-bytes", headers: [], status: 200}}},
               binary_requester: BinaryRequester,
               json_http: json_response,
               json_requester: JSONRequester
             })

    assert {:ok, resolved, "png-bytes"} =
             FileClient.download(client, %{"id" => "F123"}, 8_192)

    assert resolved["name"] == "failure.png"

    assert_received {:downloaded,
                     "https://edgeapi.files.slack.com/files-pri/T123-F123/failure.png", 8_192}
  end

  test "rejects lookalike, insecure, credentialed, and fragmented file URLs before I/O" do
    assert {:ok, client} =
             FileClient.new(%{
               binary_http: {self(), {:error, :must_not_run}},
               binary_requester: BinaryRequester,
               json_http: :unused,
               json_requester: JSONRequester
             })

    for url <- [
          "http://files.slack.com/file.png",
          "https://evilfiles.slack.com/file.png",
          "https://files.slack.com.evil.test/file.png",
          "https://user:secret@files.slack.com/file.png",
          "https://files.slack.com/file.png#fragment"
        ] do
      assert FileClient.download(
               client,
               %{
                 "id" => "F123",
                 "mimetype" => "image/png",
                 "name" => "failure.png",
                 "size" => 12,
                 "url_private_download" => url
               },
               8_192
             ) == {:error, {:slack_file_rejected, :url}}
    end

    refute_received {:downloaded, _url, _maximum}
  end

  test "normalizes Slack and transport failures without accepting malformed clients" do
    assert FileClient.new(%{}) == {:error, {:invalid_slack_file_client, :fields}}
    assert FileClient.new(:invalid) == {:error, {:invalid_slack_file_client, :fields}}

    assert FileClient.new(
             binary_http: :unused,
             binary_requester: :missing,
             json_http: :unused,
             json_requester: JSONRequester
           ) == {:error, {:invalid_slack_file_client, :requester}}

    base_file = %{
      "id" => "F123",
      "mimetype" => "image/png",
      "name" => "failure.png",
      "size" => 12,
      "url_private" => "https://files.slack.com/file.png"
    }

    assert {:ok, client} =
             FileClient.new(%{
               binary_http: {self(), {:ok, %{body: "bytes", headers: [], status: 200}}},
               binary_requester: BinaryRequester,
               json_http: :unused,
               json_requester: JSONRequester
             })

    assert {:ok, ^base_file, "bytes"} = FileClient.download(client, base_file, 64)
    assert_received {:downloaded, "https://files.slack.com/file.png", 64}

    assert FileClient.download(client, Map.delete(base_file, "id"), 64) ==
             {:error, {:slack_file_rejected, :metadata}}

    assert FileClient.download(client, base_file, 0) ==
             {:error, {:slack_file_rejected, :maximum_bytes}}

    assert FileClient.download(%{}, base_file, 64) ==
             {:error, {:slack_file_rejected, :metadata}}

    non_success = %{client | binary_http: {self(), {:ok, %{body: "gone", status: 404}}}}

    assert FileClient.download(non_success, base_file, 64) ==
             {:error, {:slack_file_unavailable, {404, "gone"}}}

    malformed = %{client | binary_http: {self(), {:ok, %{body: nil, status: nil}}}}

    assert FileClient.download(malformed, base_file, 64) ==
             {:error, {:slack_file_unavailable, :response}}
  end

  test "files.info errors stay retryable and never become guessed file metadata" do
    for {response, expected} <- [
          {{:ok, %{body: %{"error" => "file_not_found", "ok" => false}, status: 200}},
           {:error, {:slack_file_unavailable, "file_not_found"}}},
          {{:ok, %{body: "down", status: 503}},
           {:error, {:slack_file_unavailable, {503, "down"}}}},
          {{:ok, %{body: %{}, status: nil}}, {:error, {:slack_file_unavailable, :response}}}
        ] do
      assert {:ok, client} =
               FileClient.new(%{
                 binary_http: {self(), {:error, :must_not_run}},
                 binary_requester: BinaryRequester,
                 json_http: response,
                 json_requester: JSONRequester
               })

      assert FileClient.download(client, %{"id" => "F123"}, 64) == expected
    end

    refute_received {:downloaded, _url, _maximum}
  end
end
