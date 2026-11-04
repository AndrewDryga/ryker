defmodule Ryker.Retention.Creation do
  @moduledoc "Durable creation evidence for cleanup of an unbound local session."
  alias Ryker.CanonicalJSON
  alias Ryker.CoopFleet
  alias Ryker.Repo
  alias Ryker.Work

  @doc "No create, an exact created resource, or the original key that still needs reconciliation."
  def resolve(%Work.Session{} = session) do
    if Repo.in_transaction?() do
      resolve_in_transaction(session)
    else
      Repo.transaction(fn -> resolve_in_transaction(session) end)
      |> transaction_result()
    end
  end

  defp transaction_result({:ok, result}), do: result
  defp transaction_result({:error, reason}), do: {:error, reason}

  defp resolve_in_transaction(session) do
    deadline = cleanup_deadline(session)

    # A long resource wait may have many proven failed physical creates.
    # Bound each read, not the amount of valid evidence that can be reconciled.
    session.id
    |> CoopFleet.Command.Query.creates()
    |> Repo.stream(max_rows: 100)
    |> Enum.reduce_while(%{pending: nil, created: nil}, fn command, state ->
      result =
        if deadline_expired?(deadline),
          do: {:error, :retention_lease_lost},
          else: resolve_command(session, command, deadline)

      combine(result, state)
    end)
    |> finish()
  end

  defp cleanup_deadline(%Work.Session{
         cleanup_lease_ref: lease,
         cleanup_lease_expires_at: %DateTime{} = expires
       })
       when is_binary(lease),
       do: System.monotonic_time(:millisecond) + DateTime.diff(expires, Repo.now!(), :millisecond)

  defp cleanup_deadline(_session), do: nil
  defp deadline_expired?(nil), do: false
  defp deadline_expired?(deadline), do: System.monotonic_time(:millisecond) >= deadline

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
    if cleanup_lookup_allowed?(session, worker_id),
      do: lookup_resolution(resolve(session), session, worker_id, key),
      else: false
  end

  defp cleanup_lookup_allowed?(
         %Work.Session{
           cleanup_status: :close_pending,
           cleanup_lease_ref: lease,
           cleanup_lease_expires_at: %DateTime{} = expires
         },
         worker_id
       )
       when is_binary(lease) and is_binary(worker_id),
       do: DateTime.compare(expires, Repo.now!()) == :gt

  defp cleanup_lookup_allowed?(_session, _worker_id), do: false

  defp lookup_resolution({:pending, command}, session, worker_id, key),
    do: lookup_command?(session, command, worker_id, key)

  defp lookup_resolution({:ok, {:created, command, _id}}, session, worker_id, key),
    do: lookup_command?(session, command, worker_id, key)

  defp lookup_resolution({:ok, :absent}, session, worker_id, key) do
    # A terminal reply may arrive in the poll delivering this GET. The same
    # original-key read remains harmless; no new create is admitted.
    query =
      session.id
      |> CoopFleet.Command.Query.creates()
      |> CoopFleet.Command.Query.by_worker_id(worker_id)

    query =
      if is_binary(key),
        do: CoopFleet.Command.Query.by_idempotency_key(query, key),
        else: query

    command = query |> CoopFleet.Command.Query.limit_to(1) |> Repo.peek()
    lookup_command?(session, command, worker_id, key)
  end

  defp lookup_resolution(_result, _session, _worker_id, _key), do: false

  defp lookup_command?(_session, nil, _worker_id, _key), do: false

  defp lookup_command?(session, command, worker_id, key) do
    command.worker_id == worker_id and (is_nil(key) or key == command.idempotency_key) and
      on_original_holder?(session, command)
  end

  defp resolve_command(session, %CoopFleet.Command{placement_id: nil} = command, _deadline) do
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

  defp resolve_command(session, command, deadline) do
    if exact_create?(session, command),
      do: resolve_exact_command(command, deadline),
      else: {:error, :retention_creation_provenance_mismatch}
  end

  defp resolve_exact_command(command, deadline) do
    original = operation(command.result)

    state = %{
      terminal: if(terminal?(original), do: original),
      any_operation: not is_nil(original)
    }

    command
    |> CoopFleet.Command.Query.select_creation_reconciliation_results()
    |> Repo.stream(max_rows: 100)
    |> Enum.reduce_while(state, &fold_reconciliation(&1, &2, original, deadline))
    |> finish_command(command)
  end

  defp fold_reconciliation(result, state, original, deadline) do
    if deadline_expired?(deadline) do
      {:halt, {:error, :retention_lease_lost}}
    else
      observed = operation(result)
      state = %{state | any_operation: state.any_operation or not is_nil(observed)}

      if same_operation?(observed, original) and terminal?(observed),
        do: terminal_result(observed, state),
        else: {:cont, state}
    end
  end

  defp terminal_result(result, %{terminal: nil} = state),
    do: {:cont, %{state | terminal: result}}

  defp terminal_result(result, state) do
    fields = ~w(id method state resource_type resource_id)

    if Map.take(result, fields) == Map.take(state.terminal, fields),
      do: {:cont, state},
      else: {:halt, {:error, :retention_creation_ambiguous}}
  end

  defp finish_command({:error, reason}, _command), do: {:error, reason}

  defp finish_command(%{any_operation: false}, command) do
    if refused?(command), do: :absent, else: {:pending, command}
  end

  defp finish_command(%{terminal: nil}, command), do: {:pending, command}
  defp finish_command(%{terminal: result}, command), do: creation_result(result, command)

  # Ryker refused the create before delivering it, or the worker refused it before sending it to
  # its daemon: Coop reports that as invalid_command, a definite failure its daemon never saw
  # (workerconnector.ErrRequestRejected).
  defp refused?(%CoopFleet.Command{
         status: :failed,
         delivered_at: nil,
         error: %{"code" => code},
         result: nil
       })
       when code in ["invalid_command", "operation_not_enqueued"], do: true

  defp refused?(%CoopFleet.Command{
         status: :failed,
         error: %{"code" => "invalid_command"},
         result: nil
       }),
       do: true

  defp refused?(_command), do: false

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

  defp combine(:absent, state), do: {:cont, state}
  defp combine({:error, reason}, _state), do: {:halt, {:error, reason}}

  defp combine({:pending, command}, state),
    do: {:cont, %{state | pending: state.pending || command}}

  defp combine({:created, command, id}, %{created: nil} = state),
    do: {:cont, %{state | created: {command, id}}}

  defp combine({:created, _command, _id}, state),
    do: {:cont, %{state | created: :ambiguous}}

  defp finish({:error, reason}), do: {:error, reason}
  defp finish(%{pending: %CoopFleet.Command{} = command}), do: {:pending, command}
  defp finish(%{pending: nil, created: nil}), do: {:ok, :absent}

  defp finish(%{pending: nil, created: :ambiguous}),
    do: {:error, :retention_creation_ambiguous}

  defp finish(%{pending: nil, created: {command, id}}), do: {:ok, {:created, command, id}}
end
