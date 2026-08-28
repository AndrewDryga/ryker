defmodule Responder.Coop.Client do
  @moduledoc """
  Bounded HTTP client for Coop's owner-only Unix session API.

  It never opens a TCP connection and never accepts repository, model, or tool
  authority from an incoming event. Those remain in Coop's named policy.
  """

  @behaviour Responder.Coop.API

  alias Responder.CanonicalJSON

  @fields [:finch, :receive_timeout, :socket]
  @max_response_bytes 3 * 1_024 * 1_024

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
  def create_session(%__MODULE__{} = client, key, policy, task) do
    with :ok <- reference(key, :idempotency_key),
         :ok <- reference(policy, :policy),
         :ok <- reference(task, :task) do
      request(client, :post, "/v1/sessions",
        body: CanonicalJSON.encode!(%{"policy" => policy, "task" => task}),
        headers: [
          {"content-type", "application/json"},
          {"idempotency-key", key},
          {"prefer", "respond-async"}
        ]
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
  def submit_turn(client, session_id, key, expected_revision, prompt, schema) do
    with {:ok, session_id} <- path_id(session_id),
         :ok <- reference(key, :idempotency_key),
         :ok <- positive_revision(expected_revision),
         :ok <- prompt(prompt),
         {:ok, contract} <- output_contract(schema) do
      mutation(client, :post, "/v1/sessions/#{session_id}/turns", key, %{
        "expected_revision" => expected_revision,
        "output_contract" => contract,
        "prompt" => prompt
      })
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

  defp mutation(client, method, path, key, document) do
    request(client, method, path,
      body: CanonicalJSON.encode!(document),
      headers: [{"content-type", "application/json"}, {"idempotency-key", key}]
    )
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

  defp decode_response(_status, body) when byte_size(body) > @max_response_bytes,
    do: {:error, {:coop_protocol_error, :response_too_large}}

  defp decode_response(status, body) do
    case Jason.decode(body) do
      {:ok, document} when status in 200..299 and is_map(document) ->
        {:ok, document}

      {:ok, %{"error" => %{"code" => code, "detail" => detail}}}
      when is_binary(code) and is_binary(detail) ->
        {:error, {:coop_error, status, code, detail}}

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
    if length(violations) in 1..20 and Enum.all?(violations, &valid_violation?/1),
      do:
        {:ok,
         %{
           "candidate_sha256" => candidate_sha256,
           "verdict" => "reject",
           "violations" => violations
         }},
      else: {:error, {:invalid_coop_request, :violations}}
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

  defp digest(value) do
    if is_binary(value) and Regex.match?(~r/^[a-f0-9]{64}$/, value),
      do: :ok,
      else: {:error, {:invalid_coop_request, :candidate_sha256}}
  end

  defp valid_violation?(value), do: bounded_text?(value, 4 * 1_024)

  defp bounded_text?(value, maximum) do
    is_binary(value) and String.valid?(value) and :binary.match(value, <<0>>) == :nomatch and
      String.trim(value) != "" and byte_size(value) <= maximum
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
