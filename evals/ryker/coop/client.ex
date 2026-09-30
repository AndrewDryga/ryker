defmodule Ryker.Coop.Client do
  @moduledoc """
  Bounded HTTP client for Coop's owner-only Unix session API.

  Eval-only: the credentialed evaluations drive their dedicated Coop daemon
  through it, and it compiles only in development and test. Product Coop work
  runs through `Ryker.CoopFleet.Client`.

  It never opens a TCP connection and never accepts repository, model, or tool
  authority from an incoming event. Eval jobs have fixed empty-workspace
  authority and an explicitly selected model target.
  """

  @behaviour Ryker.Coop.API

  alias Ryker.CanonicalJSON
  import Ecto.Query

  alias Ryker.CoopFleet.JobAuthority
  alias Ryker.Evals.Job
  alias Ryker.Repo
  alias Ryker.Work.Custody.Sessions
  alias Ryker.Work.{Session, SessionChangeset, ValidationIntent}

  @fields [:finch, :receive_timeout, :socket]
  @max_output_artifact_bytes 8 * 1_024 * 1_024
  @max_changes_page_bytes 1_024 * 1_024
  @max_response_bytes 3 * 1_024 * 1_024
  @output_artifact_media_types ~w(image/png image/jpeg image/webp image/gif)

  @enforce_keys @fields
  defstruct @fields ++ [job: nil]

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
  def prepare_create_session(client, key, policy, task, source) do
    with {:ok, _document} <- create_session_document(client, key, policy, task, source), do: :ok
  end

  @impl true
  def create_session(%__MODULE__{} = client, key, policy, task, source) do
    with {:ok, document} <- create_session_document(client, key, policy, task, source) do
      request(client, :post, "/v1/sessions",
        body: CanonicalJSON.encode!(document),
        headers: [
          {"content-type", "application/json"},
          {"idempotency-key", key},
          {"prefer", "respond-async"}
        ]
      )
    end
  end

  @impl true
  def fence_create_session(%__MODULE__{} = client, key, policy, task, source) do
    with {:ok, document} <- create_session_document(client, key, policy, task, source) do
      fence_operation(client, key, "CreateRemoteSession", document)
    end
  end

  @impl true
  def get_session(%__MODULE__{} = client, session_id) do
    with {:ok, session_id} <- path_id(session_id) do
      request(client, :get, "/v1/sessions/" <> session_id)
    end
  end

  @impl true
  def list_events(%__MODULE__{} = client, session_id, after_sequence, limit) do
    with {:ok, session_id} <- path_id(session_id),
         :ok <- event_cursor(after_sequence),
         :ok <- event_limit(limit) do
      query = URI.encode_query(%{"after" => after_sequence, "limit" => limit})
      request_list(client, "/v1/sessions/#{session_id}/events?#{query}")
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
    with {:ok, session_id} <- path_id(session_id),
         :ok <- reference(key, :idempotency_key),
         {:ok, document} <- submit_turn_document(expected_revision, prompt, schema, nil, []) do
      mutation(client, :post, "/v1/sessions/#{session_id}/turns", key, document)
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

  # Create and fence build the identical document, so a fence request hashes the
  # exact immutable job create would have sent.
  # Coop refuses a create whose job does not hash to the digest the controller
  # computed for it, so the digest travels with the job.
  defp create_session_document(client, key, selection, task, nil) do
    with :ok <- reference(key, :idempotency_key),
         :ok <- reference(task, :task),
         {:ok, {job, digest}} <- create_job(client, key, selection, task) do
      {:ok, %{"expected_job_digest" => digest, "job" => job, "task" => task}}
    end
  end

  defp create_session_document(_client, _key, _selection, _task, _source),
    do: {:error, {:invalid_coop_request, :repository_source}}

  # The standalone jobs, by the runner namespace their creates use.
  @standalone_jobs %{
    "ryker-eval-judge" => "world-judge",
    "ryker-eval-routing" => "routing-replay"
  }

  # Standalone evaluations have no Work row: a world judge, and a routing
  # replay (`Ryker.Evals.CoopRunner`). Each create pins its own kind's job on
  # the task of the run its key names. All Work/learning creates must first
  # pin the job on their exact durable execution identity, even through Unix.
  defp create_job(_client, "ryker:eval:" <> key, %{name: name} = template, task)
       when is_map_key(@standalone_jobs, name) do
    namespace = Map.fetch!(@standalone_jobs, name)

    with [^namespace, run_ref, "create"] when run_ref != "" <- String.split(key, ":"),
         true <- String.starts_with?(task, "ryker-eval:#{namespace}:#{run_ref}:"),
         {:ok, job, digest} <- Job.bind(template, task) do
      {:ok, {job, digest}}
    else
      _invalid -> {:error, :invalid_model_eval_job}
    end
  end

  defp create_job(%{job: %{name: name} = template}, key, name, task) do
    Repo.transaction(fn ->
      session = eval_session(key)

      unless not is_nil(session) and exact_create_key?(session, key) and
               Session.coop_task_ref(session) == task and session.policy == name and
               session.policy_digest == template.digest and is_nil(session.repository_ref) and
               is_nil(session.repository_source),
             do: Repo.rollback(:model_eval_session_authority_mismatch)

      with {:ok, job, digest} <- Job.bind(template, session.external_ref),
           {:ok, pinned} <- pin_job(session, job, digest),
           {:ok, _session} <- JobAuthority.validate(pinned) do
        {pinned.worker_job_document, pinned.worker_job_digest}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp create_job(_client, _key, _selection, _task),
    do: {:error, :invalid_model_eval_job}

  defp eval_session(key) do
    query = from(session in Session, lock: "FOR UPDATE")

    case String.split(key, ":") do
      ["ryker", "work", "create", id, "g" <> generation] ->
        with {:ok, id} <- Ecto.UUID.cast(id),
             {generation, ""} <- Integer.parse(generation) do
          Repo.one(
            from(session in query,
              where: session.id == ^id and session.create_generation == ^generation
            )
          )
        else
          _invalid -> nil
        end

      ["ryker", "learning", "create", id] ->
        case Ecto.UUID.cast(id) do
          {:ok, id} -> Repo.one(from(session in query, where: session.learning_run_id == ^id))
          :error -> nil
        end

      _invalid ->
        nil
    end
  end

  defp exact_create_key?(%Session{execution_kind: :work} = session, key),
    do: key == Sessions.create_operation_key(session)

  defp exact_create_key?(%Session{execution_kind: :learning, learning_run_id: id}, key),
    do: key == "ryker:learning:create:#{id}"

  defp exact_create_key?(_session, _key), do: false

  defp pin_job(
         %{
           worker_job_document: nil,
           worker_job_digest: nil,
           coop_session_id: nil,
           cleanup_status: :active
         } = session,
         job,
         digest
       ),
       do: session |> SessionChangeset.pin_worker_job(job, digest) |> Repo.update()

  defp pin_job(%{worker_job_document: job, worker_job_digest: digest} = session, job, digest),
    do: {:ok, session}

  defp pin_job(_session, _job, _digest), do: {:error, :model_eval_session_authority_mismatch}

  defp controller_tools(%{"endpoint" => endpoint, "token" => token} = binding)
       when map_size(binding) == 2 and is_binary(endpoint) and is_binary(token) do
    with %URI{
           scheme: "https",
           host: host,
           path: path,
           userinfo: nil,
           query: nil,
           fragment: nil
         }
         when is_binary(host) and host != "" and is_binary(path) and path != "" <-
           URI.parse(endpoint),
         true <- byte_size(endpoint) <= 2_048,
         true <- Regex.match?(~r/\A[A-Za-z0-9_-]{32,256}\z/, token) do
      {:ok, binding}
    else
      _invalid -> {:error, {:invalid_coop_controller_tools, :fields}}
    end
  end

  defp controller_tools(_binding), do: {:error, {:invalid_coop_controller_tools, :fields}}

  defp submit_turn_document(expected_revision, prompt, schema, binding, artifacts) do
    with :ok <- positive_revision(expected_revision),
         :ok <- prompt(prompt),
         {:ok, contract} <- output_contract(schema),
         {:ok, binding} <- optional_controller_tools(binding),
         {:ok, artifacts} <- input_artifacts(artifacts) do
      document = %{
        "expected_revision" => expected_revision,
        "output_contract" => contract,
        "prompt" => prompt
      }

      document = if artifacts == [], do: document, else: Map.put(document, "artifacts", artifacts)
      {:ok, if(binding, do: Map.put(document, "controller_tools", binding), else: document)}
    end
  end

  defp optional_controller_tools(nil), do: {:ok, nil}
  defp optional_controller_tools(binding), do: controller_tools(binding)

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

  defp request_list(client, path) do
    request = Finch.build(:get, "http://localhost" <> path, [], nil, unix_socket: client.socket)

    case Finch.request(request, client.finch, receive_timeout: client.receive_timeout) do
      {:ok, %Finch.Response{status: status, body: response_body}} ->
        decode_list_response(status, response_body)

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

  defp decode_list_response(_status, body) when byte_size(body) > @max_response_bytes,
    do: {:error, {:coop_protocol_error, :response_too_large}}

  defp decode_list_response(status, body) do
    case Jason.decode(body) do
      {:ok, document} when status in 200..299 and is_list(document) ->
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
    if Map.keys(Map.delete(attributes, :job)) |> Enum.sort() == Enum.sort(@fields),
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

      not is_nil(client.job) and not match?({:ok, _, _}, Job.bind(client.job, "eval-validation")) ->
        {:error, {:invalid_coop_client, :job}}

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

  defp event_cursor(value) when is_integer(value) and value >= 0, do: :ok
  defp event_cursor(_value), do: {:error, {:invalid_coop_request, :event_cursor}}

  defp event_limit(value) when is_integer(value) and value in 1..1_000, do: :ok
  defp event_limit(_value), do: {:error, {:invalid_coop_request, :event_limit}}

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
