defmodule Responder.Slack.UploadClientTest do
  use ExUnit.Case, async: false

  import Plug.Conn

  alias Responder.Slack.UploadClient

  defmodule UploadPlug do
    @behaviour Plug

    @impl true
    def init(options), do: options

    @impl true
    def call(conn, test_pid) do
      {:ok, body, conn} = read_body(conn)

      send(test_pid, {
        :upload,
        conn.request_path,
        get_req_header(conn, "content-length"),
        get_req_header(conn, "content-type"),
        body
      })

      case conn.request_path do
        "/ok" -> send_resp(conn, 200, "OK - uploaded")
        "/too-large" -> send_resp(conn, 200, String.duplicate("x", 64 * 1_024 + 1))
        "/error" -> send_resp(conn, 503, "try later")
      end
    end
  end

  test "streams exact raw bytes and bounds Slack's upload response" do
    port = unused_port!()

    child =
      Bandit.child_spec(
        ip: {127, 0, 0, 1},
        plug: {UploadPlug, self()},
        port: port,
        startup_log: false
      )
      |> Map.put(:id, :slack_upload_client_test_server)

    start_supervised!(child)
    origin = "http://127.0.0.1:#{port}"

    assert {:ok, client} =
             UploadClient.new(
               base_origin: origin,
               finch: Responder.CoopFinch,
               receive_timeout: 2_000
             )

    assert :ok = UploadClient.upload(client, origin <> "/ok", "exact bytes", "image/png")

    assert_receive {:upload, "/ok", ["11"], ["image/png"], "exact bytes"}

    assert UploadClient.upload(client, origin <> "/error", "bytes", "image/gif") ==
             {:error, {:slack_http_error, 503, "try later"}}

    assert UploadClient.upload(client, origin <> "/too-large", "bytes", "image/webp") ==
             {:error, {:delivery_protocol_error, :response_too_large}}

    unavailable_origin = "http://127.0.0.1:#{unused_port!()}"

    assert {:ok, unavailable} =
             UploadClient.new(
               base_origin: unavailable_origin,
               finch: Responder.CoopFinch,
               receive_timeout: 100
             )

    assert {:error, {:delivery_transport_unavailable, _reason}} =
             UploadClient.upload(
               unavailable,
               unavailable_origin <> "/upload",
               "bytes",
               "image/png"
             )
  end

  test "accepts only bounded raw uploads to Slack's exact file host" do
    assert {:ok, client} =
             UploadClient.new(
               base_origin: "https://files.slack.com",
               finch: Responder.CoopFinch,
               receive_timeout: 2_000
             )

    for url <- [
          "http://files.slack.com/upload/v1/example",
          "https://files.slack.com.attacker.test/upload",
          "https://user@files.slack.com/upload",
          "https://files.slack.com/upload#fragment"
        ] do
      assert UploadClient.upload(client, url, "bytes", "image/png") ==
               {:error, {:invalid_slack_upload, :url}}
    end

    assert UploadClient.upload(client, "https://files.slack.com/upload", "", "image/png") ==
             {:error, {:invalid_slack_upload, :data}}

    assert UploadClient.upload(client, "https://files.slack.com/upload", "bytes", "text/html") ==
             {:error, {:invalid_slack_upload, :media_type}}

    assert UploadClient.upload(%{}, "https://files.slack.com/upload", "bytes", "image/png") ==
             {:error, {:invalid_slack_upload, :client}}

    assert UploadClient.upload(client, :invalid, "bytes", "image/png") ==
             {:error, {:invalid_slack_upload, :url}}

    valid = %{
      base_origin: "https://files.slack.com",
      finch: Responder.CoopFinch,
      receive_timeout: 2_000
    }

    for invalid <- [
          %{valid | base_origin: "https://user@files.slack.com"},
          %{valid | base_origin: "http://files.slack.com"},
          %{valid | finch: "bad"},
          %{valid | receive_timeout: 10}
        ] do
      assert {:error, {:invalid_slack_upload_client, _field}} = UploadClient.new(invalid)
    end

    assert UploadClient.new(%{}) == {:error, {:invalid_slack_upload_client, :fields}}
    assert UploadClient.new(:invalid) == {:error, {:invalid_slack_upload_client, :fields}}
  end

  defp unused_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
