defmodule Ryker.Retention.Creation do
  @moduledoc "Durable creation evidence for cleanup of an unbound local session."
  alias Ryker.CanonicalJSON
  alias Ryker.CoopFleet
  alias Ryker.Repo
  alias Ryker.Work

  @doc "No create, an exact created resource, or the original key that still needs reconciliation."
  def resolve(%Work.Session{} = session) do
    commands =
      Repo.all(CoopFleet.Command.Query.limit_to(CoopFleet.Command.Query.creates(session.id), 101))

    if length(commands) > 100 do
      {:error, :retention_creation_ambiguous}
    else
      commands
      |> Enum.map(&resolve_command(session, &1))
      |> combine()
    end
  end

  @doc "Whether the existing routing still addresses the create's exact original worker."
  def on_original_holder?(session, command) do
    workers =
      session.id
      |> CoopFleet.Placement.Query.by_session_id()
      |> CoopFleet.Placement.Query.select_worker_ids()
      |> Repo.all()

    case workers do
      [worker_id] -> worker_id == command.worker_id
      _ -> false
    end
  end

  @doc "A leased unbound cleanup may only read its original create key on its proven holder."
  def lookup_on_holder?(%Work.Session{} = session, worker_id, key \\ nil) do
    leased? =
      session.cleanup_status == :close_pending and is_binary(session.cleanup_lease_ref) and
        match?(%DateTime{}, session.cleanup_lease_expires_at) and
        DateTime.compare(session.cleanup_lease_expires_at, Repo.now!()) == :gt

    if leased? do
      case resolve(session) do
        {:pending, command} ->
          lookup_command?(session, command, worker_id, key)

        {:ok, {:created, command, _id}} ->
          lookup_command?(session, command, worker_id, key)

        {:ok, :absent} ->
          # A terminal reply may arrive in the poll delivering this GET. The
          # same original-key read remains harmless; no new create is admitted.
          session.id
          |> CoopFleet.Command.Query.creates()
          |> CoopFleet.Command.Query.limit_to(100)
          |> Repo.all()
          |> Enum.any?(&lookup_command?(session, &1, worker_id, key))

        _ ->
          false
      end
    else
      false
    end
  end

  defp lookup_command?(session, command, worker_id, key) do
    command.worker_id == worker_id and (is_nil(key) or key == command.idempotency_key) and
      on_original_holder?(session, command)
  end

  defp resolve_command(session, %CoopFleet.Command{placement_id: nil} = command) do
    if CoopFleet.ControlPlane.Commands.local_fence?(command) and is_nil(command.delivered_at) and
         is_nil(command.result) and
         command.payload ==
           CoopFleet.ControlPlane.Commands.create_intent(
             session,
             Work.Session.coop_task_ref(session)
           ) and
         command.payload_fingerprint == CanonicalJSON.digest(command.payload),
       do: :absent,
       else: {:error, :retention_creation_provenance_mismatch}
  end

  defp resolve_command(session, command) do
    if exact_create?(session, command),
      do: resolve_exact_command(command),
      else: {:error, :retention_creation_provenance_mismatch}
  end

  defp resolve_exact_command(command) do
    operation = operation(command.result)

    reconciliations =
      command
      |> CoopFleet.Command.Query.creation_reconciliations()
      |> Repo.all()

    reconciled =
      reconciliations
      |> Enum.map(&operation(&1.result))
      |> Enum.filter(&(same_operation?(&1, operation) and terminal?(&1)))

    results = if terminal?(operation), do: [operation | reconciled], else: reconciled

    cond do
      length(reconciliations) > 100 ->
        {:error, :retention_creation_ambiguous}

      locally_rejected?(command) and is_nil(operation) and
          Enum.all?(reconciliations, &is_nil(operation(&1.result))) ->
        :absent

      true ->
        terminal_result(results, command)
    end
  end

  defp terminal_result(results, command) do
    case Enum.uniq_by(results, &Map.take(&1, ~w(id method state resource_type resource_id))) do
      [result] -> creation_result(result, command)
      [] -> {:pending, command}
      _ -> {:error, :retention_creation_ambiguous}
    end
  end

  defp locally_rejected?(%CoopFleet.Command{
         status: :failed,
         delivered_at: nil,
         error: %{"code" => code},
         result: nil
       })
       when code in ["invalid_command", "operation_not_enqueued"], do: true

  defp locally_rejected?(_command), do: false

  defp exact_create?(session, command) do
    command.payload_fingerprint == command_fingerprint(command) and
      exact_job?(session, command.payload) and
      Repo.exists?(CoopFleet.Placement.Query.by_command(command))
  end

  defp exact_job?(session, payload) do
    job = payload["job"]

    is_map(job) and job["job_ref"] == session.external_ref and
      payload["external_ref"] == Work.Session.coop_task_ref(session) and
      is_binary(payload["job_digest"]) and
      CanonicalJSON.worker_digest(job) == payload["job_digest"] and
      pinned_job?(session, job, payload["job_digest"])
  end

  defp pinned_job?(%Work.Session{worker_job_document: nil}, _job, _digest), do: true

  defp pinned_job?(session, job, digest),
    do: job == session.worker_job_document and digest == session.worker_job_digest

  defp command_fingerprint(command) do
    CanonicalJSON.digest(%{
      "idempotency_key" => command.idempotency_key,
      "kind" => command.kind,
      "payload" => command.payload,
      "placement_id" => command.placement_id,
      "version" => command.command_version
    })
  end

  defp operation(%{"status" => status, "body" => body}) when status in 200..299 and is_map(body),
    do: Map.get(body, "operation", body)

  defp operation(_result), do: nil

  defp same_operation?(%{"id" => id, "method" => "CreateRemoteSession"}, nil)
       when is_binary(id), do: true

  defp same_operation?(
         %{"id" => id, "method" => "CreateRemoteSession"},
         %{"id" => id, "method" => "CreateRemoteSession"}
       )
       when is_binary(id), do: true

  defp same_operation?(_result, _original), do: false

  defp terminal?(%{"id" => id, "method" => "CreateRemoteSession", "state" => state})
       when is_binary(id) and state in ["succeeded", "failed"],
       do: true

  defp terminal?(_operation), do: false

  defp creation_result(%{"state" => "failed"} = result, command) do
    if is_nil(result["resource_id"]), do: :absent, else: {:pending, command}
  end

  defp creation_result(
         %{"state" => "succeeded", "resource_type" => "session", "resource_id" => id},
         command
       )
       when is_binary(id) and byte_size(id) in 1..1_024,
       do: {:created, command, id}

  defp creation_result(_result, _command), do: {:error, :retention_creation_provenance_mismatch}

  defp combine(results) do
    errors = Enum.filter(results, &match?({:error, _}, &1))
    pending = Enum.filter(results, &match?({:pending, _}, &1))
    created = Enum.filter(results, &match?({:created, _, _}, &1))

    case {errors, pending, created} do
      {[error | _], _, _} -> error
      {[], [{:pending, command} | _], _} -> {:pending, command}
      {[], [], []} -> {:ok, :absent}
      {[], [], [{:created, command, id}]} -> {:ok, {:created, command, id}}
      _ -> {:error, :retention_creation_ambiguous}
    end
  end
end
