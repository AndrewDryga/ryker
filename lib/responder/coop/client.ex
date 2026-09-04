defmodule Responder.Coop.Client do
  @moduledoc """
  Bounded HTTP client for Coop's owner-only Unix session API.

  It never opens a TCP connection and never accepts repository, model, or tool
  authority from an incoming event. Those remain in Coop's named policy.
  """

  @behaviour Responder.Coop.API

  alias Responder.CanonicalJSON
  alias Responder.Work.ValidationIntent

  @fields [:finch, :receive_timeout, :socket]
  @max_output_artifact_bytes 8 * 1_024 * 1_024
  @max_changes_page_bytes 1_024 * 1_024
  @max_review_patch_bytes 64 * 1_024 * 1_024
  @max_response_bytes 3 * 1_024 * 1_024
  @output_artifact_media_types ~w(image/png image/jpeg image/webp image/gif)

  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{
          finch: atom(),
          receive_timeout: pos_integer(),
          socket: String.t()
        }

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attributes) do
    with {:ok, attributes} <- normalize_attributes(attributes),
         client <- struct!(__MODULE__, attributes),
         :ok <- validate(client) do
      {:ok, client}
    end
  end

  @impl true
  def operation_by_key(%__MODULE__{} = client, key) do
    with :ok <- reference(key, :idempotency_key) do
      case request(client, :get, "/v1/operations?" <> URI.encode_query(%{"key" => key})) do
        {:error, {:coop_error, 404, "operation_not_found", _detail}} -> :not_found
        result -> result
      end
    end
  end

  @impl true
  def capabilities(%__MODULE__{} = client), do: request(client, :get, "/v1/capabilities")

  @impl true
  def create_session(%__MODULE__{} = client, key, policy, task) do
    with :ok <- reference(key, :idempotency_key),
         :ok <- reference(policy, :policy),
         :ok <- reference(task, :task) do
      request(client, :post, "/v1/sessions",
        body: CanonicalJSON.encode!(create_session_document(policy, task)),
        headers: [
          {"content-type", "application/json"},
          {"idempotency-key", key},
          {"prefer", "respond-async"}
        ]
      )
    end
  end

  @impl true
  def create_bound_session(%__MODULE__{} = client, key, policy, task, binding) do
    with :ok <- reference(key, :idempotency_key),
         :ok <- reference(policy, :policy),
         :ok <- reference(task, :task),
         {:ok, binding} <- responder_binding(binding) do
      request(client, :post, "/v1/sessions",
        body: CanonicalJSON.encode!(create_session_document(policy, task, binding)),
        headers: [
          {"content-type", "application/json"},
          {"idempotency-key", key},
          {"prefer", "respond-async"}
        ]
      )
    end
  end

  @impl true
  def fence_create_session(%__MODULE__{} = client, key, policy, task) do
    with :ok <- reference(key, :idempotency_key),
         :ok <- reference(policy, :policy),
         :ok <- reference(task, :task) do
      fence_operation(
        client,
        key,
        "CreateRemoteSession",
        create_session_document(policy, task)
      )
    end
  end

  @impl true
  def fence_bound_session(%__MODULE__{} = client, key, policy, task, binding) do
    with :ok <- reference(key, :idempotency_key),
         :ok <- reference(policy, :policy),
         :ok <- reference(task, :task),
         {:ok, binding} <- responder_binding(binding) do
      fence_operation(
        client,
        key,
        "CreateRemoteSession",
        create_session_document(policy, task, binding)
      )
    end
  end

  @impl true
  def get_session(%__MODULE__{} = client, session_id) do
    with {:ok, session_id} <- path_id(session_id) do
      request(client, :get, "/v1/sessions/" <> session_id)
    end
  end

  @impl true
  def get_changes(%__MODULE__{} = client, session_id) do
    with {:ok, session_id} <- path_id(session_id) do
      request(client, :get, "/v1/sessions/#{session_id}/changes")
    end
  end

  @impl true
  def get_changes_page(%__MODULE__{} = client, session_id, patch_offset, patch_limit) do
    with {:ok, session_id} <- path_id(session_id),
         :ok <- patch_offset(patch_offset),
         :ok <- patch_limit(patch_limit) do
      query =
        URI.encode_query(%{
          "patch_limit" => patch_limit,
          "patch_offset" => patch_offset
        })

      request(client, :get, "/v1/sessions/#{session_id}/changes?#{query}")
    end
  end

  @impl true
  def run_review(client, session_id, key, expected_revision) do
    with {:ok, session_id} <- path_id(session_id),
         :ok <- reference(key, :idempotency_key),
         :ok <- positive_revision(expected_revision) do
      mutation(client, :post, "/v1/sessions/#{session_id}/review", key, %{
        "expected_revision" => expected_revision
      })
    end
  end

  @impl true
  def get_review_patch(client, artifact_id, expected_sha256, expected_bytes) do
    with {:ok, artifact_id} <- path_id(artifact_id),
         :ok <- digest(expected_sha256),
         true <- is_integer(expected_bytes) and expected_bytes in 1..@max_review_patch_bytes do
      path = "/v1/operations/#{artifact_id}/review-patch"

      request_verified_binary(
        client,
        path,
        "text/x-diff",
        @max_review_patch_bytes,
        expected_sha256,
        expected_bytes
      )
    else
      false -> {:error, {:invalid_coop_request, :patch_bytes}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def get_session_review_patch(
        client,
        _session_id,
        artifact_id,
        expected_sha256,
        expected_bytes
      ),
      do: get_review_patch(client, artifact_id, expected_sha256, expected_bytes)

  @impl true
  def close_session(client, session_id, key, expected_revision) do
    with {:ok, session_id} <- path_id(session_id),
         :ok <- reference(key, :idempotency_key),
         :ok <- positive_revision(expected_revision) do
      mutation(client, :post, "/v1/sessions/#{session_id}/close", key, %{
        "expected_revision" => expected_revision
      })
    end
  end

  @impl true
  def plan_discard(
        client,
        session_id,
        key,
        expected_revision,
        accept_dirty,
        accept_unmerged
      ) do
    with {:ok, session_id} <- path_id(session_id),
         :ok <- reference(key, :idempotency_key),
         :ok <- positive_revision(expected_revision),
         :ok <- boolean(accept_dirty, :accept_dirty),
         :ok <- boolean(accept_unmerged, :accept_unmerged) do
      mutation(client, :post, "/v1/sessions/#{session_id}/discard-plan", key, %{
        "accept_dirty" => accept_dirty,
        "accept_unmerged" => accept_unmerged,
        "expected_revision" => expected_revision
      })
    end
  end

  @impl true
  def discard_session(client, session_id, key, plan_operation_id) do
    with {:ok, session_id} <- path_id(session_id),
         :ok <- reference(key, :idempotency_key),
         :ok <- reference(plan_operation_id, :plan_operation_id) do
      mutation(client, :post, "/v1/sessions/#{session_id}/discard", key, %{
        "plan_operation_id" => plan_operation_id
      })
    end
  end

  @impl true
  def submit_turn(client, session_id, key, expected_revision, prompt, schema) do
    submit_turn_with_artifacts(client, session_id, key, expected_revision, prompt, schema, [])
  end

  @impl true
  def submit_turn_with_artifacts(
        client,
        session_id,
        key,
        expected_revision,
        prompt,
        schema,
        artifacts
      ) do
    with {:ok, session_id} <- path_id(session_id),
         :ok <- reference(key, :idempotency_key),
         {:ok, document} <- submit_turn_document(expected_revision, prompt, schema, artifacts) do
      mutation(client, :post, "/v1/sessions/#{session_id}/turns", key, document)
    end
  end

  @impl true
  def fence_submit_turn(client, session_id, key, expected_revision, prompt, schema) do
    fence_submit_turn_with_artifacts(
      client,
      session_id,
      key,
      expected_revision,
      prompt,
      schema,
      []
    )
  end

  @impl true
  def fence_submit_turn_with_artifacts(
        client,
        session_id,
        key,
        expected_revision,
        prompt,
        schema,
        artifacts
      ) do
    with {:ok, session_id} <- path_id(session_id),
         :ok <- reference(key, :idempotency_key),
         {:ok, document} <- submit_turn_document(expected_revision, prompt, schema, artifacts) do
      fence_operation(
        client,
        key,
        "SubmitTurn",
        Map.put(document, "session_id", session_id)
      )
    end
  end

  @impl true
  def get_turn(%__MODULE__{} = client, session_id, turn_id) do
    with {:ok, session_id} <- path_id(session_id),
         {:ok, turn_id} <- path_id(turn_id) do
      request(client, :get, "/v1/sessions/#{session_id}/turns/#{turn_id}")
    end
  end

  @impl true
  def get_output_artifact(%__MODULE__{} = client, session_id, turn_id, artifact_id) do
    with {:ok, session_id} <- path_id(session_id),
         {:ok, turn_id} <- path_id(turn_id),
         {:ok, artifact_id} <- path_id(artifact_id) do
      path = "/v1/sessions/#{session_id}/turns/#{turn_id}/artifacts/#{artifact_id}"

      request_binary(client, path, artifact_id)
    end
  end

  @impl true
  def cancel_turn(client, session_id, turn_id, key, expected_revision) do
    with {:ok, session_id} <- path_id(session_id),
         {:ok, turn_id} <- path_id(turn_id),
         :ok <- reference(key, :idempotency_key),
         :ok <- positive_revision(expected_revision) do
      mutation(client, :post, "/v1/sessions/#{session_id}/turns/#{turn_id}/cancel", key, %{
        "expected_revision" => expected_revision
      })
    end
  end

  @impl true
  def validate_candidate(client, session_id, turn_id, key, candidate_sha256, verdict) do
    with {:ok, session_id} <- path_id(session_id),
         {:ok, turn_id} <- path_id(turn_id),
         :ok <- reference(key, :idempotency_key),
         :ok <- digest(candidate_sha256),
         {:ok, document} <- validation_document(candidate_sha256, verdict) do
      mutation(
        client,
        :post,
        "/v1/sessions/#{session_id}/turns/#{turn_id}/validation",
        key,
        document
      )
    end
  end

  @impl true
  def submit_frozen_turn(
        client,
        session_id,
        key,
        expected_revision,
        submission,
        binding,
        artifacts
      ) do
    with {:ok, session_id} <- path_id(session_id),
         :ok <- reference(key, :idempotency_key),
         {:ok, document} <-
           submit_turn_document(
             expected_revision,
             submission["prompt"],
             submission["output_schema"],
             binding,
             artifacts
           ) do
      mutation(client, :post, "/v1/sessions/#{session_id}/turns", key, document)
    end
  end

  @impl true
  def fence_frozen_turn(
        client,
        session_id,
        key,
        expected_revision,
        submission,
        binding,
        artifacts
      ) do
    with {:ok, session_id} <- path_id(session_id),
         :ok <- reference(key, :idempotency_key),
         {:ok, document} <-
           submit_turn_document(
             expected_revision,
             submission["prompt"],
             submission["output_schema"],
             binding,
             artifacts
           ) do
      fence_operation(client, key, "SubmitTurn", Map.put(document, "session_id", session_id))
    end
  end

  @impl true
  def validate_frozen_candidate(client, session_id, turn_id, key, _attempt, sha256, verdict) do
    validate_candidate(client, session_id, turn_id, key, sha256, verdict)
  end

  defp mutation(client, method, path, key, document) do
    request(client, method, path,
      body: CanonicalJSON.encode!(document),
      headers: [{"content-type", "application/json"}, {"idempotency-key", key}]
    )
  end

  defp fence_operation(client, key, method, document) do
    mutation(client, :post, "/v1/operations/fence", key, %{
      "method" => method,
      "request" => document
    })
  end

  defp create_session_document(policy, task), do: %{"policy" => policy, "task" => task}

  defp create_session_document(policy, task, binding) do
    create_session_document(policy, task) |> Map.put("responder_binding", binding)
  end

  defp responder_binding(%{"endpoint" => endpoint, "token" => token} = binding)
       when map_size(binding) == 2 and is_binary(endpoint) and is_binary(token) do
    with %URI{
           scheme: "https",
           host: host,
           path: "/v1/state-tools/mcp",
           userinfo: nil,
           query: nil,
           fragment: nil
         }
         when is_binary(host) and host != "" <- URI.parse(endpoint),
         true <- byte_size(endpoint) <= 2_048,
         true <- Regex.match?(~r/\A[A-Za-z0-9_-]{32,256}\z/, token) do
      {:ok, binding}
    else
      _invalid -> {:error, {:invalid_coop_responder_binding, :fields}}
    end
  end

  defp responder_binding(_binding), do: {:error, {:invalid_coop_responder_binding, :fields}}

  defp submit_turn_document(expected_revision, prompt, schema, artifacts),
    do: submit_turn_document(expected_revision, prompt, schema, nil, artifacts)

  defp submit_turn_document(expected_revision, prompt, schema, binding, artifacts) do
    with :ok <- positive_revision(expected_revision),
         :ok <- prompt(prompt),
         {:ok, contract} <- output_contract(schema),
         {:ok, binding} <- optional_responder_binding(binding),
         {:ok, artifacts} <- input_artifacts(artifacts) do
      document = %{
        "expected_revision" => expected_revision,
        "output_contract" => contract,
        "prompt" => prompt
      }

      document = if artifacts == [], do: document, else: Map.put(document, "artifacts", artifacts)
      {:ok, if(binding, do: Map.put(document, "responder_binding", binding), else: document)}
    end
  end

  defp optional_responder_binding(nil), do: {:ok, nil}
  defp optional_responder_binding(binding), do: responder_binding(binding)

  defp boolean(value, _field) when is_boolean(value), do: :ok
  defp boolean(_value, field), do: {:error, {:invalid_coop_request, field}}

  defp input_artifacts(artifacts) when is_list(artifacts) and length(artifacts) <= 5 do
    with {:ok, documents, total} <-
           Enum.reduce_while(artifacts, {:ok, [], 0}, &append_input_artifact/2) do
      _total = total
      {:ok, Enum.reverse(documents)}
    end
  end

  defp input_artifacts(_artifacts), do: {:error, {:invalid_coop_request, :artifacts}}

  defp input_artifact(%{
         "data" => data,
         "media_type" => media_type,
         "name" => name,
         "sha256" => sha256
       })
       when is_binary(data) and is_binary(media_type) and is_binary(name) and is_binary(sha256) do
    if byte_size(data) > 0 and byte_size(data) <= 8 * 1_024 * 1_024 and
         sha256(data) == sha256 do
      {:ok,
       %{
         "data" => Base.encode64(data),
         "media_type" => media_type,
         "name" => name,
         "sha256" => sha256
       }, byte_size(data)}
    else
      {:error, {:invalid_coop_request, :artifacts}}
    end
  end

  defp input_artifact(_artifact), do: {:error, {:invalid_coop_request, :artifacts}}

  defp append_input_artifact(artifact, {:ok, values, total}) do
    case input_artifact(artifact) do
      {:ok, document, bytes} when total <= 8 * 1_024 * 1_024 - bytes ->
        {:cont, {:ok, [document | values], total + bytes}}

      {:ok, _document, _bytes} ->
        {:halt, {:error, {:invalid_coop_request, :artifacts}}}

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  defp request(client, method, path, options \\ []) do
    headers = Keyword.get(options, :headers, [])
    body = Keyword.get(options, :body)

    request =
      Finch.build(method, "http://localhost" <> path, headers, body, unix_socket: client.socket)

    case Finch.request(request, client.finch, receive_timeout: client.receive_timeout) do
      {:ok, %Finch.Response{status: status, body: response_body}} ->
        decode_response(status, response_body)

      {:error, reason} ->
        {:error, {:coop_unavailable, reason}}
    end
  end

  defp request_binary(client, path, artifact_id) do
    request =
      Finch.build(
        :get,
        "http://localhost" <> path,
        [{"accept", Enum.join(@output_artifact_media_types, ",")}],
        nil,
        unix_socket: client.socket
      )

    initial = %{body: [], bytes: 0, headers: %{}, status: nil, too_large: false}

    stream = fn
      {:status, status}, state ->
        {:cont, %{state | status: status}}

      {:headers, headers}, state ->
        normalized = Map.new(headers, fn {name, value} -> {String.downcase(name), value} end)
        {:cont, %{state | headers: Map.merge(state.headers, normalized)}}

      {:data, chunk}, state when state.bytes <= @max_output_artifact_bytes - byte_size(chunk) ->
        {:cont, %{state | body: [chunk | state.body], bytes: state.bytes + byte_size(chunk)}}

      {:data, _chunk}, state ->
        {:halt, %{state | too_large: true}}

      {:trailers, _headers}, state ->
        {:cont, state}
    end

    case Finch.stream_while(request, client.finch, initial, stream,
           receive_timeout: client.receive_timeout
         ) do
      {:ok, state} -> decode_binary_artifact(state, artifact_id)
      {:error, reason, _state} -> {:error, {:coop_unavailable, reason}}
    end
  end

  defp request_verified_binary(
         client,
         path,
         expected_media_type,
         maximum_bytes,
         expected_sha256,
         expected_bytes
       ) do
    request =
      Finch.build(
        :get,
        "http://localhost" <> path,
        [{"accept", expected_media_type}],
        nil,
        unix_socket: client.socket
      )

    initial = %{body: [], bytes: 0, headers: %{}, status: nil, too_large: false}

    stream = fn
      {:status, status}, state ->
        {:cont, %{state | status: status}}

      {:headers, headers}, state ->
        normalized = Map.new(headers, fn {name, value} -> {String.downcase(name), value} end)
        {:cont, %{state | headers: Map.merge(state.headers, normalized)}}

      {:data, chunk}, state when state.bytes <= maximum_bytes - byte_size(chunk) ->
        {:cont, %{state | body: [chunk | state.body], bytes: state.bytes + byte_size(chunk)}}

      {:data, _chunk}, state ->
        {:halt, %{state | too_large: true}}

      {:trailers, _headers}, state ->
        {:cont, state}
    end

    case Finch.stream_while(request, client.finch, initial, stream,
           receive_timeout: client.receive_timeout
         ) do
      {:ok, state} ->
        decode_verified_binary(
          state,
          expected_media_type,
          expected_sha256,
          expected_bytes
        )

      {:error, reason, _state} ->
        {:error, {:coop_unavailable, reason}}
    end
  end

  defp decode_verified_binary(%{too_large: true}, _media_type, _sha256, _bytes),
    do: {:error, {:coop_protocol_error, :review_patch_too_large}}

  defp decode_verified_binary(
         %{body: chunks, headers: headers, status: 200},
         expected_media_type,
         expected_sha256,
         expected_bytes
       ) do
    body = chunks |> Enum.reverse() |> IO.iodata_to_binary()
    content_type = headers["content-type"]

    media_type =
      content_type && content_type |> String.split(";", parts: 2) |> hd() |> String.trim()

    with true <- media_type == expected_media_type,
         true <- body != "" and byte_size(body) == expected_bytes,
         {^expected_bytes, ""} <- Integer.parse(headers["content-length"] || ""),
         {:ok, ^expected_sha256} <- artifact_etag(headers["etag"]),
         true <- sha256(body) == expected_sha256 do
      {:ok, body}
    else
      _invalid -> {:error, {:coop_protocol_error, :review_patch}}
    end
  end

  defp decode_verified_binary(%{body: chunks, status: status}, _media_type, _sha256, _bytes)
       when is_integer(status) do
    chunks |> Enum.reverse() |> IO.iodata_to_binary() |> then(&decode_response(status, &1))
  end

  defp decode_verified_binary(_state, _media_type, _sha256, _bytes),
    do: {:error, {:coop_protocol_error, :review_patch}}

  defp decode_binary_artifact(%{too_large: true}, _artifact_id),
    do: {:error, {:coop_protocol_error, :artifact_too_large}}

  defp decode_binary_artifact(%{body: chunks, headers: headers, status: 200}, artifact_id) do
    body = chunks |> Enum.reverse() |> IO.iodata_to_binary()

    with true <- byte_size(body) in 1..@max_output_artifact_bytes,
         {:ok, media_type} <- artifact_media_type(headers["content-type"]),
         {:ok, expected_bytes} <- artifact_content_length(headers["content-length"]),
         true <- expected_bytes == byte_size(body),
         {:ok, expected_sha256} <- artifact_etag(headers["etag"]),
         true <- sha256(body) == expected_sha256 do
      {:ok,
       %{
         "bytes" => byte_size(body),
         "data" => body,
         "id" => artifact_id,
         "media_type" => media_type,
         "sha256" => expected_sha256
       }}
    else
      _invalid -> {:error, {:coop_protocol_error, :output_artifact}}
    end
  end

  defp decode_binary_artifact(%{body: chunks, status: status}, _artifact_id)
       when is_integer(status) do
    chunks |> Enum.reverse() |> IO.iodata_to_binary() |> then(&decode_response(status, &1))
  end

  defp decode_binary_artifact(_state, _artifact_id),
    do: {:error, {:coop_protocol_error, :output_artifact}}

  defp artifact_media_type(value) when is_binary(value) do
    media_type =
      value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()

    if media_type in @output_artifact_media_types, do: {:ok, media_type}, else: :error
  end

  defp artifact_media_type(_value), do: :error

  defp artifact_content_length(value) when is_binary(value) do
    case Integer.parse(value) do
      {bytes, ""} when bytes in 1..@max_output_artifact_bytes -> {:ok, bytes}
      _invalid -> :error
    end
  end

  defp artifact_content_length(_value), do: :error

  defp artifact_etag(<<?\", digest::binary-size(64), ?\">>) do
    if Regex.match?(~r/^[a-f0-9]{64}$/, digest), do: {:ok, digest}, else: :error
  end

  defp artifact_etag(_value), do: :error

  defp decode_response(_status, body) when byte_size(body) > @max_response_bytes,
    do: {:error, {:coop_protocol_error, :response_too_large}}

  defp decode_response(status, body) do
    case Jason.decode(body) do
      {:ok, document} when status in 200..299 and is_map(document) ->
        {:ok, document}

      {:ok, %{"error" => %{"code" => code} = error}} when is_binary(code) ->
        case Map.fetch(error, "detail") do
          {:ok, detail} when is_binary(detail) ->
            {:error, {:coop_error, status, code, detail}}

          :error ->
            {:error, {:coop_error, status, code, ""}}

          {:ok, _invalid_detail} ->
            {:error, {:coop_protocol_error, {:unexpected_status, status}}}
        end

      {:ok, _document} ->
        {:error, {:coop_protocol_error, {:unexpected_status, status}}}

      {:error, _reason} ->
        {:error, {:coop_protocol_error, :invalid_json}}
    end
  end

  defp output_contract(schema) when is_map(schema) do
    case CanonicalJSON.validate(schema, max_bytes: 256 * 1_024) do
      :ok ->
        encoded = CanonicalJSON.encode!(schema)

        {:ok,
         %{
           "json_schema" => schema,
           "require_semantic_validation" => true,
           "sha256" => sha256(encoded)
         }}

      {:error, reason} ->
        {:error, {:invalid_coop_request, :schema, reason}}
    end
  end

  defp output_contract(_schema), do: {:error, {:invalid_coop_request, :schema}}

  defp validation_document(candidate_sha256, :accept) do
    {:ok, %{"candidate_sha256" => candidate_sha256, "verdict" => "accept"}}
  end

  defp validation_document(candidate_sha256, {:reject, violations}) when is_list(violations) do
    case ValidationIntent.new({:reject, violations}, nil) do
      {:ok, %{"violations" => normalized}} ->
        {:ok,
         %{
           "candidate_sha256" => candidate_sha256,
           "verdict" => "reject",
           "violations" => normalized
         }}

      {:error, _reason} ->
        {:error, {:invalid_coop_request, :violations}}
    end
  end

  defp validation_document(_candidate_sha256, _verdict),
    do: {:error, {:invalid_coop_request, :verdict}}

  defp normalize_attributes(attributes) when is_list(attributes) do
    if Keyword.keyword?(attributes) and
         Enum.uniq(Keyword.keys(attributes)) == Keyword.keys(attributes) do
      attributes |> Map.new() |> normalize_attributes()
    else
      {:error, {:invalid_coop_client, :fields}}
    end
  end

  defp normalize_attributes(%{} = attributes) do
    if Map.keys(attributes) |> Enum.sort() == Enum.sort(@fields),
      do: {:ok, attributes},
      else: {:error, {:invalid_coop_client, :fields}}
  end

  defp normalize_attributes(_attributes), do: {:error, {:invalid_coop_client, :fields}}

  defp validate(client) do
    cond do
      not is_atom(client.finch) ->
        {:error, {:invalid_coop_client, :finch}}

      not is_integer(client.receive_timeout) or client.receive_timeout < 100 ->
        {:error, {:invalid_coop_client, :receive_timeout}}

      not valid_socket?(client.socket) ->
        {:error, {:invalid_coop_client, :socket}}

      true ->
        :ok
    end
  end

  defp valid_socket?(value) do
    is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.starts_with?(value, "/") and byte_size(value) <= 1_024
  end

  defp path_id(value) do
    with :ok <- reference(value, :resource_id),
         true <- Regex.match?(~r/^[A-Za-z0-9_.:-]+$/, value) do
      {:ok, value}
    else
      _other -> {:error, {:invalid_coop_request, :resource_id}}
    end
  end

  defp reference(value, field) do
    if bounded_text?(value, 1_024),
      do: :ok,
      else: {:error, {:invalid_coop_request, field}}
  end

  defp prompt(value) do
    if bounded_text?(value, 256 * 1_024),
      do: :ok,
      else: {:error, {:invalid_coop_request, :prompt}}
  end

  defp positive_revision(value) when is_integer(value) and value > 0, do: :ok
  defp positive_revision(_value), do: {:error, {:invalid_coop_request, :expected_revision}}

  defp patch_offset(value) when is_integer(value) and value >= 0, do: :ok
  defp patch_offset(_value), do: {:error, {:invalid_coop_request, :patch_offset}}

  defp patch_limit(value) when is_integer(value) and value in 1..@max_changes_page_bytes, do: :ok
  defp patch_limit(_value), do: {:error, {:invalid_coop_request, :patch_limit}}

  defp digest(value) do
    if is_binary(value) and Regex.match?(~r/^[a-f0-9]{64}$/, value),
      do: :ok,
      else: {:error, {:invalid_coop_request, :candidate_sha256}}
  end

  defp bounded_text?(value, maximum) do
    is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != "" and byte_size(value) <= maximum
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
