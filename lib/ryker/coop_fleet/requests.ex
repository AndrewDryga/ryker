defmodule Ryker.CoopFleet.Requests do
  @moduledoc false

  # Command kinds are private Work bookkeeping. The worker receives only ordinary
  # Coop HTTP requests, so adding an API endpoint never changes its wire protocol.
  alias Ryker.{Artifacts, CanonicalJSON, Repo}
  alias Ryker.CoopFleet.WorkspaceCheckpointTransfer

  def encode(kind, payload, placement) do
    request_for(kind, payload, placement)
  rescue
    _error in [ArgumentError, FunctionClauseError, KeyError] -> {:error, :invalid_coop_request}
  end

  defp request_for("api_request", request, _placement), do: {:ok, request}

  defp request_for(
         "create_session",
         %{"external_ref" => task, "job" => job, "job_digest" => digest},
         _
       ) do
    {:ok,
     request("POST", "/v1/sessions", %{
       "task" => task,
       "job" => job,
       "expected_job_digest" => digest
     })}
  end

  defp request_for("ensure_workspace", %{"checkpoint" => saved} = payload, _) do
    with %WorkspaceCheckpointTransfer{} = transfer <-
           Repo.get(WorkspaceCheckpointTransfer, saved["transfer_id"]),
         true <-
           transfer.bundle_sha256 == saved["sha256"] and
             transfer.bundle_byte_size == saved["byte_size"] do
      {:ok,
       %{
         "method" => "POST",
         "path" => session_path(payload) <> "/workspace/restore",
         "headers" => %{
           "content-type" => transfer.descriptor["bundle"]["media_type"],
           "x-coop-expected-revision" => to_string(payload["expected_revision"]),
           "x-coop-workspace-checkpoint" =>
             transfer.descriptor |> CanonicalJSON.encode!() |> Base.encode64()
         },
         "body_ref" => %{
           "sha256" => transfer.bundle_sha256,
           "byte_size" => transfer.bundle_byte_size
         }
       }}
    else
      _ -> {:error, :checkpoint_not_available}
    end
  end

  defp request_for("ensure_workspace", payload, _) do
    {:ok,
     request(
       "POST",
       session_path(payload) <> "/workspace",
       Map.take(payload, ~w(expected_revision task))
     )}
  end

  defp request_for("submit_turn", %{"submission" => submission} = payload, _) do
    with {:ok, artifacts} <- Artifacts.fetch_many(submission["input_artifact_refs"]) do
      schema = submission["output_schema"]

      body = %{
        "expected_revision" => payload["expected_revision"],
        "prompt" => submission["prompt"],
        "output_contract" => %{
          "json_schema" => schema,
          "sha256" => CanonicalJSON.worker_digest(schema),
          "require_semantic_validation" => true
        }
      }

      body =
        if artifacts == [],
          do: body,
          else: Map.put(body, "artifacts", Enum.map(artifacts, &artifact/1))

      body =
        if payload["controller_tools"],
          do: Map.put(body, "controller_tools", payload["controller_tools"]),
          else: body

      {:ok, request("POST", session_path(payload) <> "/turns", body)}
    end
  end

  defp request_for("checkpoint_workspace", payload, placement) do
    body =
      payload
      |> Map.take(~w(expected_revision repository_ref session_ref))
      |> Map.put("placement_generation", placement.generation)

    {:ok, request("POST", session_path(payload) <> "/checkpoint", body)}
  end

  defp request_for("get_changes_page", payload, _) do
    query = URI.encode_query(Map.take(payload, ~w(patch_offset patch_limit)))
    {:ok, request("GET", session_path(payload) <> "/changes?" <> query)}
  end

  defp request_for("get_output_artifact", payload, _) do
    {:ok, request("GET", turn_path(payload) <> "/artifacts/" <> segment(payload["artifact_ref"]))}
  end

  defp request_for("get_checkpoint_bundle", payload, _) do
    {:ok,
     request(
       "GET",
       "/v1/operations/" <> segment(payload["operation_id"]) <> "/checkpoint-bundle"
     )}
  end

  defp request_for("get_review", payload, _) do
    {:ok,
     request("GET", session_path(payload) <> "/reviews/" <> segment(payload["operation_id"]))}
  end

  defp request_for("get_review_gate_output", payload, _) do
    query =
      case payload["cursor"] do
        nil -> ""
        cursor -> "?" <> URI.encode_query(%{"cursor" => cursor})
      end

    path =
      session_path(payload) <> "/reviews/" <> segment(payload["operation_id"]) <> "/gate-output"

    {:ok, request("GET", path <> query)}
  end

  defp request_for("reconcile_operation", payload, _) do
    {:ok,
     request("GET", "/v1/operations?" <> URI.encode_query(%{"key" => payload["operation_key"]}))}
  end

  defp request_for("fence_operation", payload, _),
    do: {:ok, request("POST", "/v1/operations/fence", Map.take(payload, ~w(method request)))}

  defp request_for(kind, payload, _)
       when kind in ~w(get_session get_session_evidence get_changes get_turn) do
    path =
      case kind do
        "get_session" -> session_path(payload)
        "get_session_evidence" -> session_path(payload) <> "/evidence"
        "get_changes" -> session_path(payload) <> "/changes"
        "get_turn" -> turn_path(payload)
      end

    {:ok, request("GET", path)}
  end

  defp request_for(kind, payload, _)
       when kind in ~w(run_review plan_discard discard_session close_session prepare_session cancel_turn validate_candidate) do
    {path, fields} =
      case kind do
        "run_review" ->
          {session_path(payload) <> "/review", ~w(expected_revision)}

        # Coop starts the session's agent before it answers, and keeps it
        # running for the job's warm idle timeout.
        "prepare_session" ->
          {session_path(payload) <> "/prepare", ~w(expected_revision)}

        "plan_discard" ->
          {session_path(payload) <> "/discard-plan",
           ~w(expected_revision accept_dirty accept_unmerged)}

        "discard_session" ->
          {session_path(payload) <> "/discard", ~w(plan_operation_id)}

        "close_session" ->
          {session_path(payload) <> "/close", ~w(expected_revision)}

        "cancel_turn" ->
          {turn_path(payload) <> "/cancel", ~w(expected_revision)}

        "validate_candidate" ->
          {turn_path(payload) <> "/validation", ~w(candidate_sha256 verdict violations)}
      end

    {:ok, request("POST", path, Map.take(payload, fields))}
  end

  defp request_for(_kind, _payload, _placement), do: {:error, :invalid_coop_request}

  defp request(method, path), do: %{"method" => method, "path" => path}
  defp request(method, path, body), do: Map.put(request(method, path), "body", body)
  defp session_path(payload), do: "/v1/sessions/" <> segment(payload["coop_session_id"])

  defp turn_path(payload),
    do: session_path(payload) <> "/turns/" <> segment(payload["coop_turn_id"])

  defp segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp artifact(value),
    do: %{
      "name" => value.name,
      "media_type" => value.media_type,
      "sha256" => value.sha256,
      "data" => Base.encode64(value.data)
    }
end
