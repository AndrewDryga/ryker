defmodule Ryker.CoopFleet.Router do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias Ryker.CoopFleet.{
    ArtifactTransport,
    ControlPlane,
    Enrollment,
    Protocol,
    WorkspaceCheckpoint
  }

  alias Ryker.StateTools.Binding
  alias Ryker.StateTools.Router, as: StateToolsRouter

  @maximum_document_bytes 1_048_576
  @maximum_artifact_bytes 8 * 1_024 * 1_024
  @maximum_review_patch_bytes 64 * 1_024 * 1_024

  @impl Plug
  def init(options), do: options

  @impl Plug
  def call(
        %Plug.Conn{method: "POST", request_path: "/v1/state-tools/mcp"} = conn,
        options
      ) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, binding} <- Binding.resolve(token),
         {:ok, state_tools} <- Keyword.fetch(options, :state_tools) do
      router_options =
        [token: token, binding: binding, capabilities: state_tools.capabilities]
        # Never sign history cursors with the caller's active-turn bearer.
        |> Keyword.put(:cursor_secret, Map.get(state_tools, :token_secret))
        |> maybe_put(:additional_tools, Map.get(state_tools, :additional_tools))
        |> maybe_put(:additional_call, Map.get(state_tools, :additional_call))
        |> maybe_put(:answer_authorizer, Map.get(state_tools, :answer_authorizer))
        |> StateToolsRouter.init()

      conn
      |> Map.put(:path_info, ["mcp"])
      |> Map.put(:request_path, "/mcp")
      |> StateToolsRouter.call(router_options)
    else
      _unauthorized -> json_error(conn, 401, "unauthorized")
    end
  end

  def call(
        %Plug.Conn{
          method: "GET",
          path_info: [
            "v1",
            "coop-workers",
            "commands",
            command_id,
            "workspace-checkpoints",
            transfer_id
          ]
        } = conn,
        options
      ) do
    with {:ok, certificate} <- client_certificate(conn),
         {:ok, key} <- Keyword.fetch(options, :checkpoint_key),
         {:ok, secrets} <- Keyword.fetch(options, :checkpoint_secrets),
         {:ok, stored} <-
           ArtifactTransport.fetch_checkpoint_for_restore(
             certificate,
             command_id,
             transfer_id,
             key,
             secrets
           ) do
      conn
      |> put_resp_content_type(WorkspaceCheckpoint.bundle_media_type())
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header(
        "x-responder-checkpoint-descriptor",
        stored.checkpoint |> Jason.encode!() |> Base.url_encode64(padding: false)
      )
      |> put_resp_header("x-responder-checkpoint-sha256", stored.checkpoint["bundle"]["sha256"])
      |> send_resp(200, stored.bundle)
    else
      {:error, :coop_worker_certificate_not_authorized} -> json_error(conn, 401, "unauthorized")
      {:error, :client_certificate} -> json_error(conn, 401, "unauthorized")
      :error -> json_error(conn, 500, "checkpoint_custody_not_configured")
      {:error, _reason} -> json_error(conn, 404, "not_found")
    end
  end

  def call(
        %Plug.Conn{
          method: "PUT",
          path_info: [
            "v1",
            "coop-workers",
            "commands",
            command_id,
            "workspace-checkpoints",
            checkpoint_ref
          ]
        } = conn,
        options
      ) do
    with {:ok, certificate} <- client_certificate(conn),
         {:ok, metadata} <- checkpoint_headers(conn, checkpoint_ref),
         {:ok, data, conn} <- bounded_checkpoint_body(conn),
         true <- byte_size(data) == metadata.byte_size,
         {:ok, key} <- Keyword.fetch(options, :checkpoint_key),
         {:ok, secrets} <- Keyword.fetch(options, :checkpoint_secrets),
         {:ok, transfer} <-
           ArtifactTransport.put_checkpoint(
             certificate,
             command_id,
             checkpoint_ref,
             %{bundle: data, checkpoint: metadata.checkpoint},
             key,
             secrets
           ) do
      json_response(conn, 200, %{
        "bytes" => transfer.bundle_byte_size,
        "checkpoint_ref" => transfer.checkpoint_ref,
        "sha256" => transfer.bundle_sha256,
        "state" => "stored",
        "transfer_id" => transfer.id
      })
    else
      {:error, :coop_worker_certificate_not_authorized} -> json_error(conn, 401, "unauthorized")
      {:error, :client_certificate} -> json_error(conn, 401, "unauthorized")
      {:error, :content_type} -> json_error(conn, 415, "unsupported_media_type")
      {:error, :document_too_large, conn} -> json_error(conn, 413, "document_too_large")
      {:error, reason} -> reject(conn, "checkpoint upload", reason)
      :error -> json_error(conn, 500, "checkpoint_custody_not_configured")
      false -> reject(conn, "checkpoint upload", :byte_size_mismatch)
    end
  end

  @impl Plug
  def call(
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

  def call(
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

  @impl Plug
  def call(%Plug.Conn{method: "POST", request_path: "/v1/coop-workers/poll"} = conn, options) do
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

  def call(
        %Plug.Conn{
          method: "GET",
          path_info: [
            "v1",
            "coop-workers",
            "commands",
            command_id,
            "input-artifacts",
            artifact_ref
          ]
        } = conn,
        _options
      ) do
    with {:ok, certificate} <- client_certificate(conn),
         {:ok, artifact} <- ArtifactTransport.fetch_input(certificate, command_id, artifact_ref) do
      conn
      |> put_resp_content_type(artifact.media_type)
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_header(
        "x-responder-artifact-name",
        Base.url_encode64(artifact.name, padding: false)
      )
      |> put_resp_header("x-responder-artifact-sha256", artifact.sha256)
      |> send_resp(200, artifact.data)
    else
      {:error, :coop_worker_certificate_not_authorized} -> json_error(conn, 401, "unauthorized")
      {:error, :client_certificate} -> json_error(conn, 401, "unauthorized")
      {:error, _reason} -> json_error(conn, 404, "not_found")
    end
  end

  def call(
        %Plug.Conn{
          method: "PUT",
          path_info: ["v1", "coop-workers", "commands", command_id, "review-patches", artifact_id]
        } = conn,
        _options
      ) do
    with {:ok, certificate} <- client_certificate(conn),
         {:ok, metadata} <- review_patch_headers(conn),
         {:ok, data, conn} <- bounded_review_patch_body(conn),
         true <- byte_size(data) == metadata.byte_size,
         {:ok, transfer} <-
           ArtifactTransport.put_review_patch(
             certificate,
             command_id,
             artifact_id,
             %{data: data, sha256: metadata.sha256}
           ) do
      json_response(conn, 200, %{
        "artifact_id" => transfer.artifact_id,
        "bytes" => transfer.byte_size,
        "sha256" => transfer.sha256,
        "transfer_id" => transfer.id
      })
    else
      {:error, :coop_worker_certificate_not_authorized} -> json_error(conn, 401, "unauthorized")
      {:error, :client_certificate} -> json_error(conn, 401, "unauthorized")
      {:error, :content_type} -> json_error(conn, 415, "unsupported_media_type")
      {:error, :document_too_large, conn} -> json_error(conn, 413, "document_too_large")
      {:error, reason} -> reject(conn, "review patch upload", reason)
      false -> reject(conn, "review patch upload", :byte_size_mismatch)
    end
  end

  def call(
        %Plug.Conn{
          method: "PUT",
          path_info: [
            "v1",
            "coop-workers",
            "commands",
            command_id,
            "output-artifacts",
            artifact_ref
          ]
        } = conn,
        _options
      ) do
    with {:ok, certificate} <- client_certificate(conn),
         {:ok, metadata} <- artifact_headers(conn),
         {:ok, data, conn} <- bounded_artifact_body(conn),
         true <- byte_size(data) == metadata.byte_size,
         {:ok, transfer} <-
           ArtifactTransport.put_output(
             certificate,
             command_id,
             artifact_ref,
             Map.put(metadata, :data, data) |> Map.delete(:byte_size)
           ) do
      json_response(conn, 200, %{
        "artifact_ref" => transfer.artifact_ref,
        "bytes" => transfer.byte_size,
        "media_type" => transfer.media_type,
        "name" => transfer.name,
        "sha256" => transfer.sha256,
        "transfer_id" => transfer.id
      })
    else
      {:error, :coop_worker_certificate_not_authorized} -> json_error(conn, 401, "unauthorized")
      {:error, :client_certificate} -> json_error(conn, 401, "unauthorized")
      {:error, :content_type} -> json_error(conn, 415, "unsupported_media_type")
      {:error, :document_too_large, conn} -> json_error(conn, 413, "document_too_large")
      {:error, reason} -> reject(conn, "artifact upload", reason)
      false -> reject(conn, "artifact upload", :byte_size_mismatch)
    end
  end

  def call(conn, _options), do: json_error(conn, 404, "not_found")

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

  defp artifact_headers(conn) do
    with [content_type] <- get_req_header(conn, "content-type"),
         true <- content_type in ["image/png", "image/jpeg", "image/webp", "image/gif"],
         [encoded_name] <- get_req_header(conn, "x-responder-artifact-name"),
         {:ok, name} <- Base.url_decode64(encoded_name, padding: false),
         [sha256] <- get_req_header(conn, "x-responder-artifact-sha256"),
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, sha256),
         [byte_size] <- get_req_header(conn, "content-length"),
         {byte_size, ""} <- Integer.parse(byte_size),
         true <- byte_size in 1..@maximum_artifact_bytes do
      {:ok, %{byte_size: byte_size, media_type: content_type, name: name, sha256: sha256}}
    else
      false -> {:error, :content_type}
      _invalid -> {:error, :artifact_headers}
    end
  end

  defp review_patch_headers(conn) do
    with ["text/x-diff"] <- get_req_header(conn, "content-type"),
         [sha256] <- get_req_header(conn, "x-responder-artifact-sha256"),
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, sha256),
         [byte_size] <- get_req_header(conn, "content-length"),
         {byte_size, ""} <- Integer.parse(byte_size),
         true <- byte_size in 1..@maximum_review_patch_bytes do
      {:ok, %{byte_size: byte_size, sha256: sha256}}
    else
      false -> {:error, :content_type}
      _invalid -> {:error, :artifact_headers}
    end
  end

  defp checkpoint_headers(conn, checkpoint_ref) do
    with [content_type] <- get_req_header(conn, "content-type"),
         true <- content_type == WorkspaceCheckpoint.bundle_media_type(),
         [encoded] <- get_req_header(conn, "x-responder-checkpoint-descriptor"),
         true <- byte_size(encoded) <= 64 * 1_024,
         {:ok, descriptor} <- Base.url_decode64(encoded, padding: false),
         {:ok, checkpoint} <- WorkspaceCheckpoint.decode(descriptor),
         true <- checkpoint["checkpoint_ref"] == checkpoint_ref,
         [sha256] <- get_req_header(conn, "x-responder-checkpoint-sha256"),
         true <- sha256 == checkpoint["bundle"]["sha256"],
         [byte_size] <- get_req_header(conn, "content-length"),
         {byte_size, ""} <- Integer.parse(byte_size),
         true <- byte_size == checkpoint["bundle"]["byte_size"] do
      {:ok, %{byte_size: byte_size, checkpoint: checkpoint}}
    else
      false -> {:error, :content_type}
      _invalid -> {:error, :checkpoint_headers}
    end
  end

  defp poll_options(options) do
    case Keyword.get(options, :state_tools) do
      %{token_secret: secret} when is_binary(secret) -> [state_tools_secret: secret]
      _unconfigured -> []
    end
  end

  defp bounded_body(conn) do
    case read_body(conn, length: @maximum_document_bytes, read_length: 64 * 1_024) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:error, :document_too_large, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bounded_artifact_body(conn) do
    case read_body(conn, length: @maximum_artifact_bytes, read_length: 64 * 1_024) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:error, :document_too_large, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bounded_review_patch_body(conn) do
    case read_body(conn, length: @maximum_review_patch_bytes, read_length: 64 * 1_024) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _partial, conn} -> {:error, :document_too_large, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bounded_checkpoint_body(conn) do
    case read_body(conn,
           length: WorkspaceCheckpoint.maximum_bundle_bytes(),
           read_length: 64 * 1_024
         ) do
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
