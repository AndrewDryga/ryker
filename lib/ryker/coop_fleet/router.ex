defmodule Ryker.CoopFleet.Router do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Ryker.CoopFleet.{
    Bodies,
    ControlPlane,
    Enrollment,
    Protocol,
    PublicationGrants,
    SourceGrants
  }

  alias Ryker.HTTPConnection
  alias Ryker.StateTools.Binding
  alias Ryker.StateTools.Router, as: StateToolsRouter

  @maximum_document_bytes 1_048_576

  # The state tools' options are built and checked once, when the listener
  # starts; a request adds only its turn's binding. Each request used to rebuild
  # the whole tool catalog to check the platform tools against it.
  @impl Plug
  def init(options) do
    case Keyword.fetch(options, :state_tools) do
      {:ok, state_tools} ->
        Keyword.put(options, :state_tools_router, state_tools_router(state_tools))

      :error ->
        options
    end
  end

  @impl Plug
  def call(conn, options),
    do: conn |> HTTPConnection.close_after_refusal() |> route(options)

  defp route(
         %Plug.Conn{
           method: "GET",
           path_info: ["v1", "coop-workers", "commands", id, "request-body"]
         } = conn,
         options
       ) do
    with {:ok, certificate} <- client_certificate(conn),
         {:ok, _command} <- Bodies.authorize(certificate, id),
         {:ok, root} <- Keyword.fetch(options, :body_root),
         {:ok, key} <- Keyword.fetch(options, :checkpoint_key),
         {:ok, body, _reference} <- Bodies.fetch(root, id, :request),
         {:ok, conn} <-
           Bodies.with_stream(body, key, fn stream ->
             send_request_body(conn, certificate, id, stream)
           end) do
      conn
    else
      {:error, :body_not_authorized} -> json_error(conn, 404, "not_found")
      {:error, :client_certificate} -> json_error(conn, 401, "unauthorized")
      _ -> json_error(conn, 503, "body_storage_unavailable")
    end
  end

  defp route(
         %Plug.Conn{
           method: "PUT",
           path_info: ["v1", "coop-workers", "commands", id, "response-body"]
         } = conn,
         options
       ) do
    with {:ok, certificate} <- client_certificate(conn),
         {:ok, command} <- Bodies.authorize(certificate, id),
         {:ok, root} <- Keyword.fetch(options, :body_root),
         {:ok, key} <- Keyword.fetch(options, :checkpoint_key),
         {:ok, reference} <- body_reference(conn),
         :ok <- allowed_size(command, root, reference),
         {:ok, conn} <- Bodies.receive_response(root, id, reference, certificate, conn, key) do
      json_response(conn, 200, reference)
    else
      {:error, :response_body_too_large} ->
        json_error(conn, 413, "response_body_too_large")

      {:error, :insufficient_storage} ->
        json_error(conn, 507, "insufficient_storage")

      {:error, :body_not_authorized} ->
        json_error(conn, 404, "not_found")

      {:error, :client_certificate} ->
        json_error(conn, 401, "unauthorized")

      {:error, :body_conflict} ->
        json_error(conn, 409, "body_conflict")

      {:error, reason}
      when reason in [:invalid_body_reference, :body_size_mismatch, :body_identity_mismatch] ->
        reject(conn, "response body", reason)

      _ ->
        json_error(conn, 503, "body_storage_unavailable")
    end
  end

  defp route(
         %Plug.Conn{method: "POST", request_path: "/v1/state-tools/mcp"} = conn,
         options
       ) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, binding} <- Binding.resolve(token),
         {:ok, state_tools} <- Keyword.fetch(options, :state_tools_router) do
      conn
      |> Map.put(:path_info, ["mcp"])
      |> Map.put(:request_path, "/mcp")
      |> StateToolsRouter.call(%{state_tools | binding: binding})
    else
      _unauthorized -> json_error(conn, 401, "unauthorized")
    end
  end

  defp route(
         %Plug.Conn{
           method: "POST",
           path_info: [
             "v1",
             "coop-workers",
             "jobs",
             job_ref,
             "source-grants"
           ]
         } = conn,
         _options
       ) do
    with {:ok, certificate} <- client_certificate(conn),
         :ok <- json_content_type(conn),
         {:ok, body, conn} <- bounded_body(conn),
         {:ok, source} <- Jason.decode(body),
         {:ok, grant} <-
           SourceGrants.source_grant(certificate, job_ref, source) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> json_response(200, grant)
    else
      {:error, :coop_worker_certificate_not_authorized} -> json_error(conn, 401, "unauthorized")
      {:error, :client_certificate} -> json_error(conn, 401, "unauthorized")
      # The worker tries again on 503 and gives up on 404.
      {:error, :coop_worker_source_grant_unavailable} -> json_error(conn, 503, "unavailable")
      _unavailable -> json_error(conn, 404, "not_found")
    end
  end

  defp route(
         %Plug.Conn{
           method: "POST",
           path_info: ["v1", "coop-workers", "jobs", job_ref, "publication-grants"]
         } = conn,
         _options
       ) do
    with {:ok, certificate} <- client_certificate(conn),
         :ok <- json_content_type(conn),
         {:ok, body, conn} <- bounded_body(conn),
         {:ok, request} <- Jason.decode(body),
         {:ok, grant} <- PublicationGrants.publication_grant(certificate, job_ref, request) do
      conn |> put_resp_header("cache-control", "no-store") |> json_response(200, grant)
    else
      {:error, :client_certificate} -> json_error(conn, 401, "unauthorized")
      {:error, :publication_grant_denied} -> json_error(conn, 403, "not_authorized")
      _unavailable -> json_error(conn, 503, "unavailable")
    end
  end

  defp route(
         %Plug.Conn{method: "POST", request_path: "/v1/coop-workers/enroll"} = conn,
         options
       ) do
    with :ok <- json_content_type(conn),
         {:ok, body, conn} <- bounded_body(conn),
         {:ok, document} <- Jason.decode(body),
         {:ok, response} <- Enrollment.enroll(document, enrollment_authority(options)) do
      json_response(conn, 201, response)
    else
      {:error, reason}
      when reason in [
             :coop_worker_enrollment_not_authorized,
             :coop_worker_enrollment_token_consumed,
             :coop_worker_enrollment_token_expired
           ] ->
        json_error(conn, 401, "unauthorized")

      {:error, :content_type} ->
        json_error(conn, 415, "unsupported_media_type")

      {:error, :document_too_large, conn} ->
        json_error(conn, 413, "document_too_large")

      {:error, reason} ->
        reject(conn, "enrollment", reason)
    end
  end

  defp route(
         %Plug.Conn{method: "POST", request_path: "/v1/coop-workers/renew"} = conn,
         options
       ) do
    with {:ok, certificate} <- client_certificate(conn),
         :ok <- json_content_type(conn),
         {:ok, body, conn} <- bounded_body(conn),
         {:ok, document} <- Jason.decode(body),
         {:ok, response} <-
           Enrollment.renew(certificate, document, enrollment_authority(options)) do
      json_response(conn, 200, response)
    else
      {:error, :coop_worker_certificate_not_authorized} -> json_error(conn, 401, "unauthorized")
      {:error, :client_certificate} -> json_error(conn, 401, "unauthorized")
      {:error, :content_type} -> json_error(conn, 415, "unsupported_media_type")
      {:error, :document_too_large, conn} -> json_error(conn, 413, "document_too_large")
      {:error, reason} -> reject(conn, "renewal", reason)
    end
  end

  defp route(%Plug.Conn{method: "POST", request_path: "/v1/coop-workers/poll"} = conn, options) do
    with {:ok, certificate} <- client_certificate(conn),
         :ok <- json_content_type(conn),
         {:ok, body, conn} <- bounded_body(conn),
         {:ok, poll} <- Protocol.decode_poll(body),
         {:ok, response} <-
           ControlPlane.handle_poll_certificate(certificate, poll, poll_options(options)),
         {:ok, encoded} <- Protocol.encode_response(response) do
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, encoded)
    else
      {:error, :coop_worker_certificate_not_authorized} -> json_error(conn, 401, "unauthorized")
      {:error, :client_certificate} -> json_error(conn, 401, "unauthorized")
      {:error, :content_type} -> json_error(conn, 415, "unsupported_media_type")
      {:error, :document_too_large, conn} -> json_error(conn, 413, "document_too_large")
      {:error, reason} -> reject(conn, "poll", reason)
    end
  end

  defp route(conn, _options), do: json_error(conn, 404, "not_found")

  defp send_request_body(conn, certificate, id, stream) do
    with {:ok, _command} <- Bodies.authorize(certificate, id) do
      conn
      |> put_resp_content_type("application/octet-stream")
      |> put_resp_header("cache-control", "no-store")
      |> send_chunked(200)
      |> stream_response(stream.())
    end
  end

  defp client_certificate(conn) do
    case Plug.Conn.get_peer_data(conn) do
      %{ssl_cert: certificate} when is_binary(certificate) and byte_size(certificate) > 0 ->
        {:ok, certificate}

      _missing ->
        {:error, :client_certificate}
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token]
      when byte_size(token) >= 32 and byte_size(token) <= 256 ->
        if String.valid?(token), do: {:ok, token}, else: {:error, :authorization}

      _missing_or_ambiguous ->
        {:error, :authorization}
    end
  end

  defp state_tools_router(%{capabilities: capabilities} = state_tools) do
    # Never sign history cursors with the caller's active-turn bearer.
    [capabilities: capabilities, cursor_secret: Map.get(state_tools, :token_secret)]
    |> maybe_put(:additional_tools, Map.get(state_tools, :additional_tools))
    |> maybe_put(:additional_call, Map.get(state_tools, :additional_call))
    |> maybe_put(:answer_authorizer, Map.get(state_tools, :answer_authorizer))
    |> StateToolsRouter.init()
  end

  defp state_tools_router(_state_tools),
    do: raise(ArgumentError, "Coop worker gateway state-tools options are invalid")

  defp maybe_put(values, _key, nil), do: values
  defp maybe_put(values, key, value), do: Keyword.put(values, key, value)

  defp json_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [value] ->
        media_type =
          value |> String.downcase() |> String.split(";", parts: 2) |> hd() |> String.trim()

        if media_type == "application/json", do: :ok, else: {:error, :content_type}

      _missing_or_ambiguous ->
        {:error, :content_type}
    end
  end

  defp poll_options(options) do
    custody = Keyword.take(options, [:body_root, :checkpoint_key])

    case Keyword.get(options, :state_tools) do
      %{token_secret: %Ryker.Secret{} = secret} ->
        Keyword.put(custody, :state_tools_secret, secret)

      _unconfigured ->
        custody
    end
  end

  defp stream_response(conn, stream) do
    Enum.reduce_while(stream, {:ok, conn}, fn bytes, {:ok, conn} ->
      case chunk(conn, bytes) do
        {:ok, conn} -> {:cont, {:ok, conn}}
        {:error, _} -> {:halt, {:ok, conn}}
      end
    end)
  rescue
    _error in File.Error ->
      # Headers have already gone out. End the truncated response; the receiver
      # verifies its declared body reference and retries, never accepts partial data.
      {:ok, conn}
  end

  # Refused before a byte is read: larger than anything Ryker reads back for
  # this command, or more than the volume can hold and keep its reserve.
  defp allowed_size(command, root, %{"byte_size" => size}) do
    cond do
      size > Bodies.response_allowance(command) -> {:error, :response_body_too_large}
      not Bodies.room?(root, size) -> {:error, :insufficient_storage}
      true -> :ok
    end
  end

  defp body_reference(conn) do
    with [hash] <- get_req_header(conn, "x-coop-body-sha256"),
         [length] <- get_req_header(conn, "content-length"),
         {size, ""} <- Integer.parse(length),
         reference = %{"sha256" => hash, "byte_size" => size},
         true <- Bodies.reference?(reference) do
      {:ok, reference}
    else
      _ -> {:error, :invalid_body_reference}
    end
  end

  defp bounded_body(conn) do
    case read_body(conn, length: @maximum_document_bytes, read_length: 64 * 1_024) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:error, :document_too_large, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp json_response(conn, status, document) do
    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(document))
  end

  defp json_error(conn, status, code) do
    json_response(conn, status, %{"error" => %{"code" => code}})
  end

  # The worker only ever sees "invalid_request". On 2026-09-18 the worker
  # logged two of them while the fleet stalled and nothing on this side said
  # why. Log the reason's codes and never its values: requests carry command
  # results, session evidence and artifact bytes.
  defp reject(conn, request, reason) do
    Logger.warning("coop worker #{request} rejected: #{reason_codes(reason)}")
    json_error(conn, 400, "invalid_request")
  end

  defp reason_codes(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp reason_codes(reason) when is_tuple(reason) do
    case reason |> Tuple.to_list() |> Enum.filter(&is_atom/1) do
      [] -> "unrecognized"
      codes -> Enum.map_join(codes, " ", &Atom.to_string/1)
    end
  end

  defp reason_codes(_reason), do: "unrecognized"

  defp enrollment_authority(options) do
    Keyword.fetch!(options, :enrollment_authority)
  end
end
