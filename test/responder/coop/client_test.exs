defmodule Responder.Coop.ClientTest do
  use ExUnit.Case, async: true

  alias Responder.CanonicalJSON
  alias Responder.Coop.Client

  test "creates an asynchronous session through Coop's Unix socket" do
    response = %{
      "operation" => %{
        "id" => "op_create",
        "resource_id" => "remote_123",
        "resource_type" => "session",
        "state" => "succeeded"
      }
    }

    with_unix_server(response, fn client, request ->
      assert {:ok, ^response} =
               Client.create_session(
                 client,
                 "responder:admission:create:123",
                 "admission-read-only",
                 "responder-admission:123"
               )

      captured = request.()
      assert captured.method == "POST"
      assert captured.path == "/v1/sessions"
      assert captured.headers["idempotency-key"] == "responder:admission:create:123"
      assert captured.headers["prefer"] == "respond-async"

      assert Jason.decode!(captured.body) == %{
               "policy" => "admission-read-only",
               "task" => "responder-admission:123"
             }
    end)
  end

  test "submits the exact schema digest with semantic validation enabled" do
    response = %{
      "operation" => %{"id" => "op_turn", "state" => "succeeded"},
      "turn" => %{"id" => "turn_123", "session_id" => "remote_123", "state" => "queued"}
    }

    schema = %{
      "additionalProperties" => false,
      "properties" => %{"answer" => %{"type" => "string"}},
      "required" => ["answer"],
      "type" => "object"
    }

    with_unix_server(response, fn client, request ->
      assert {:ok, ^response} =
               Client.submit_turn(
                 client,
                 "remote_123",
                 "responder:admission:turn:123:0",
                 4,
                 "Classify this event.",
                 schema
               )

      captured = request.()
      body = Jason.decode!(captured.body)
      contract = body["output_contract"]
      expected_schema_bytes = CanonicalJSON.encode!(schema)

      expected_digest =
        :crypto.hash(:sha256, expected_schema_bytes) |> Base.encode16(case: :lower)

      assert captured.path == "/v1/sessions/remote_123/turns"
      assert body["expected_revision"] == 4
      assert body["prompt"] == "Classify this event."
      assert contract["json_schema"] == schema
      assert contract["sha256"] == expected_digest
      assert contract["require_semantic_validation"]
      assert captured.body == CanonicalJSON.encode!(body)
    end)
  end

  test "keeps bounded Coop errors structured and treats missing operations as absent" do
    error = %{
      "error" => %{"code" => "operation_not_found", "detail" => "operation not found"}
    }

    with_unix_server(error, 404, fn client, request ->
      assert :not_found = Client.operation_by_key(client, "responder:key with spaces")
      assert request.().path == "/v1/operations?key=responder%3Akey+with+spaces"
    end)
  end

  test "reads sessions and turns from exact resource paths" do
    session = %{"id" => "remote_123", "revision" => 7, "state" => "open"}

    with_unix_server(session, fn client, request ->
      assert {:ok, ^session} = Client.get_session(client, "remote_123")
      assert request.().path == "/v1/sessions/remote_123"
    end)

    turn = %{"id" => "turn_123", "session_id" => "remote_123", "state" => "running"}

    with_unix_server(turn, fn client, request ->
      assert {:ok, ^turn} = Client.get_turn(client, "remote_123", "turn_123")
      assert request.().path == "/v1/sessions/remote_123/turns/turn_123"
    end)
  end

  test "reads an existing operation by its exact key" do
    operation = %{
      "id" => "op_existing",
      "resource_id" => "remote_123",
      "resource_type" => "session",
      "state" => "succeeded"
    }

    with_unix_server(operation, fn client, request ->
      assert {:ok, ^operation} = Client.operation_by_key(client, "responder:existing")
      assert request.().path == "/v1/operations?key=responder%3Aexisting"
    end)
  end

  test "closes sessions and validates exact candidates with idempotent mutations" do
    closed = %{"session" => %{"id" => "remote_123", "revision" => 9, "state" => "closed"}}

    with_unix_server(closed, fn client, request ->
      assert {:ok, ^closed} = Client.close_session(client, "remote_123", "close:key", 8)
      captured = request.()
      assert captured.path == "/v1/sessions/remote_123/close"
      assert captured.headers["idempotency-key"] == "close:key"
      assert Jason.decode!(captured.body) == %{"expected_revision" => 8}
    end)

    digest = String.duplicate("a", 64)
    accepted = %{"turn" => %{"id" => "turn_123", "state" => "completed"}}

    with_unix_server(accepted, fn client, request ->
      assert {:ok, ^accepted} =
               Client.validate_candidate(
                 client,
                 "remote_123",
                 "turn_123",
                 "validation:accept",
                 digest,
                 :accept
               )

      captured = request.()
      assert captured.path == "/v1/sessions/remote_123/turns/turn_123/validation"

      assert Jason.decode!(captured.body) == %{
               "candidate_sha256" => digest,
               "verdict" => "accept"
             }
    end)

    rejected = %{"turn" => %{"id" => "turn_123", "state" => "running"}}

    with_unix_server(rejected, fn client, request ->
      assert {:ok, ^rejected} =
               Client.validate_candidate(
                 client,
                 "remote_123",
                 "turn_123",
                 "validation:reject",
                 digest,
                 {:reject, ["episode_ref must use an offered candidate"]}
               )

      assert Jason.decode!(request.().body) == %{
               "candidate_sha256" => digest,
               "verdict" => "reject",
               "violations" => ["episode_ref must use an offered candidate"]
             }
    end)
  end

  test "rejects malformed local requests before opening a socket" do
    assert {:error, {:invalid_coop_client, :socket}} =
             Client.new(finch: __MODULE__, receive_timeout: 1_000, socket: "tcp://coop")

    assert {:ok, client} =
             Client.new(finch: __MODULE__, receive_timeout: 1_000, socket: "/tmp/not-used.sock")

    assert {:error, {:invalid_coop_request, :resource_id}} =
             Client.get_session(client, "../../wrong")

    assert {:error, {:invalid_coop_request, :expected_revision}} =
             Client.close_session(client, "remote_123", "close:key", 0)

    assert {:error, {:invalid_coop_request, :candidate_sha256}} =
             Client.validate_candidate(
               client,
               "remote_123",
               "turn_123",
               "validation:key",
               "not-a-digest",
               :accept
             )

    assert {:error, {:invalid_coop_request, :violations}} =
             Client.validate_candidate(
               client,
               "remote_123",
               "turn_123",
               "validation:key",
               String.duplicate("a", 64),
               {:reject, []}
             )
  end

  defp with_unix_server(response, function), do: with_unix_server(response, 200, function)

  defp with_unix_server(response, status, function) do
    parent = self()
    socket_path = "/tmp/responder-coop-#{System.unique_integer([:positive])}.sock"
    File.rm(socket_path)

    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        ifaddr: {:local, socket_path}
      ])

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        captured = receive_request(socket)
        body = Jason.encode!(response)
        reason = if status == 200, do: "OK", else: "Not Found"

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 #{status} #{reason}\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
          )

        :gen_tcp.close(socket)
        send(parent, {:captured_request, self(), captured})
      end)

    finch = String.to_atom("coop_finch_#{System.unique_integer([:positive])}")
    start_supervised!({Finch, name: finch})
    assert {:ok, client} = Client.new(finch: finch, receive_timeout: 2_000, socket: socket_path)

    request = fn ->
      assert_receive {:captured_request, ^server, captured}, 2_000
      captured
    end

    try do
      function.(client, request)
    after
      :gen_tcp.close(listener)
      File.rm(socket_path)
    end
  end

  defp receive_request(socket) do
    {head, initial_body} = receive_head(socket, "")
    [request_line | header_lines] = String.split(head, "\r\n")
    [method, path, _version] = String.split(request_line, " ", parts: 3)

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    length = headers |> Map.get("content-length", "0") |> String.to_integer()
    body = if length == 0, do: "", else: recv_exact(socket, length, initial_body)

    %{body: body, headers: headers, method: method, path: path}
  end

  defp receive_head(socket, data) do
    case :binary.match(data, "\r\n\r\n") do
      {position, 4} ->
        head = binary_part(data, 0, position)
        body_start = position + 4
        body = binary_part(data, body_start, byte_size(data) - body_start)
        {head, body}

      :nomatch ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 2_000)
        receive_head(socket, data <> chunk)
    end
  end

  defp recv_exact(_socket, expected, data) when byte_size(data) == expected, do: data

  defp recv_exact(socket, expected, data) do
    {:ok, chunk} = :gen_tcp.recv(socket, expected - byte_size(data), 2_000)
    recv_exact(socket, expected, data <> chunk)
  end
end
