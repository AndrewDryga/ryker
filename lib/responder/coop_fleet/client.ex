defmodule Responder.CoopFleet.Client do
  @moduledoc """
  Coop API adapter backed by the durable outbound worker command plane.

  It preserves the existing Work executor contract while replacing direct
  Unix-socket calls with placed, leased, idempotent worker commands.
  """

  @behaviour Responder.Coop.API

  import Ecto.Query

  alias Responder.{Artifacts, CanonicalJSON}

  alias Responder.CoopFleet.{
    ArtifactTransport,
    Bridge,
    Command,
    Placement,
    Worker,
    WorkspaceCheckpointTransfer
  }

  alias Responder.Repo
  alias Responder.Work.{Session, StateBinding}

  @fields [:bridge, :bridge_options]
  @option_keys [
    :bridge,
    :capability_names,
    :capability_versions,
    :lease_seconds,
    :max_waits,
    :poll_interval_ms,
    :wait,
    :workspace_ref
  ]
  @enforce_keys @fields
  defstruct @fields

  @type t :: %__MODULE__{bridge: module(), bridge_options: keyword()}

  @repository_freshness_capability "repository-freshness"

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(options) do
    with {:ok, options} <- normalize_options(options),
         true <- valid_workspace_ref?(options[:workspace_ref]),
         true <- is_atom(Map.get(options, :bridge, Bridge)) do
      bridge = Map.get(options, :bridge, Bridge)

      {:ok,
       %__MODULE__{
         bridge: bridge,
         bridge_options:
           options
           |> Map.drop([:bridge])
           |> Map.put_new(:capability_names, ["responder-state"])
           |> Map.put_new(:capability_versions, %{})
           |> Enum.to_list()
       }}
    else
      false -> {:error, {:invalid_coop_fleet_client, :options}}
      {:error, {:invalid_coop_fleet_client, :options}} = error -> error
    end
  end

  @impl true
  def create_session(client, key, policy, task) do
    with {:ok, session} <- session_by_task_ref(task),
         true <- session.policy == policy,
         {:ok, remote} <-
           execute(
             client,
             session,
             "create_session",
             create_session_payload(session, policy, task, nil),
             key
           ) do
      ensure_workspace(client, session, remote, key)
    else
      false -> {:error, {:coop_fleet_authority_mismatch, :policy}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def create_bound_session(client, key, policy, task, binding) do
    with {:ok, session} <- session_by_task_ref(task),
         true <- session.policy == policy,
         :ok <- optional_responder_binding(binding),
         {:ok, remote} <-
           execute(
             client,
             session,
             "create_session",
             create_session_payload(session, policy, task, binding),
             key
           ) do
      ensure_workspace(client, session, remote, key)
    else
      false -> {:error, {:coop_fleet_authority_mismatch, :policy}}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_workspace(_client, %Session{workspace_task: nil}, remote, _create_key),
    do: {:ok, remote}

  defp ensure_workspace(client, %Session{workspace_task: task} = session, remote, create_key)
       when is_map(task) do
    with coop_session_id when is_binary(coop_session_id) <- remote["id"],
         revision when is_integer(revision) and revision > 0 <- remote["revision"],
         {:ok, checkpoint} <- restore_checkpoint(session) do
      key =
        "responder:workspace:" <>
          CanonicalJSON.digest(%{
            "create_key" => create_key,
            "checkpoint" => checkpoint,
            "session_id" => session.id,
            "task" => task
          })

      payload =
        %{
          "coop_session_id" => coop_session_id,
          "expected_revision" => revision,
          "task" => task
        }
        |> maybe_put_checkpoint(checkpoint)

      execute(
        client,
        session,
        "ensure_workspace",
        payload,
        key
      )
    else
      _invalid -> {:error, {:coop_protocol_error, :create_session_response}}
    end
  end

  @impl true
  def checkpoint_workspace(client, coop_session_id, key, expected_revision) do
    with {:ok, session} <- session_by_coop_id(coop_session_id),
         repository_ref when is_binary(repository_ref) <- session.repository_ref do
      execute(
        client,
        session,
        "checkpoint_workspace",
        %{
          "coop_session_id" => coop_session_id,
          "expected_revision" => expected_revision,
          "repository_ref" => repository_ref,
          "session_ref" => session.id
        },
        key
      )
    else
      _invalid -> {:error, {:coop_workspace_checkpoint_unavailable, coop_session_id}}
    end
  end

  @impl true
  def fence_create_session(client, key, policy, task) do
    with {:ok, session} <- session_by_task_ref(task),
         true <- session.policy == policy do
      fence_durable_operation(
        client,
        session,
        key,
        "create_session",
        create_session_payload(session, policy, task, nil)
      )
    else
      false -> {:error, {:coop_fleet_authority_mismatch, :policy}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def fence_bound_session(client, key, policy, task, binding) do
    with {:ok, session} <- session_by_task_ref(task),
         true <- session.policy == policy,
         :ok <- optional_responder_binding(binding) do
      fence_durable_operation(
        client,
        session,
        key,
        "create_session",
        create_session_payload(session, policy, task, binding)
      )
    else
      false -> {:error, {:coop_fleet_authority_mismatch, :policy}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def get_session(client, coop_session_id) do
    with {:ok, session} <- session_by_coop_id(coop_session_id) do
      execute_read(client, session, "get_session", %{"coop_session_id" => coop_session_id})
    end
  end

  @impl true
  def capabilities(%__MODULE__{} = client, %Session{id: session_id} = session) do
    now = database_now!()

    case Repo.one(
           from(placement in Placement,
             join: worker in Worker,
             on: worker.id == placement.worker_id,
             where:
               placement.session_id == ^session_id and
                 placement.state in [:assigning, :active, :draining, :revoking],
             select: {placement, worker},
             limit: 1
           )
         ) do
      {%Placement{state: :active, lease_expires_at: expires_at}, %Worker{} = worker}
      when not is_nil(expires_at) ->
        placed_freshness_capabilities(worker, expires_at, now)

      nil when is_nil(session.coop_session_id) ->
        configured_freshness_capabilities(client)

      _unavailable ->
        {:error, {:coop_upgrade_required, :repository_freshness_v2}}
    end
  end

  defp placed_freshness_capabilities(worker, expires_at, now) do
    if DateTime.compare(expires_at, now) == :gt,
      do: freshness_capability_document(worker.capabilities),
      else: {:error, {:coop_upgrade_required, :repository_freshness_v2}}
  end

  defp configured_freshness_capabilities(client) do
    versions = Keyword.get(client.bridge_options, :capability_versions, %{})

    if versions[@repository_freshness_capability] == "2",
      do: {:ok, %{"repository_freshness_receipt_versions" => [2]}},
      else: {:ok, %{"repository_freshness_receipt_versions" => []}}
  end

  defp freshness_capability_document(capabilities) do
    if Enum.any?(
         capabilities,
         &(&1["name"] == @repository_freshness_capability and &1["version"] == "2")
       ),
       do: {:ok, %{"repository_freshness_receipt_versions" => [2]}},
       else: {:ok, %{"repository_freshness_receipt_versions" => []}}
  end

  @impl true
  def get_changes(client, coop_session_id) do
    with {:ok, session} <- session_by_coop_id(coop_session_id) do
      execute_read(client, session, "get_changes", %{"coop_session_id" => coop_session_id})
    end
  end

  @impl true
  def get_changes_page(client, coop_session_id, patch_offset, patch_limit) do
    with {:ok, session} <- session_by_coop_id(coop_session_id) do
      execute_read(client, session, "get_changes_page", %{
        "coop_session_id" => coop_session_id,
        "patch_limit" => patch_limit,
        "patch_offset" => patch_offset
      })
    end
  end

  @impl true
  def run_review(client, coop_session_id, key, expected_revision) do
    with {:ok, session} <- session_by_coop_id(coop_session_id) do
      execute(
        client,
        session,
        "run_review",
        %{"coop_session_id" => coop_session_id, "expected_revision" => expected_revision},
        key
      )
    end
  end

  @impl true
  def get_review_patch(_client, _artifact_id, _expected_sha256, _expected_bytes),
    do: {:error, :coop_fleet_review_patch_session_required}

  @impl true
  def get_session_review_patch(
        client,
        coop_session_id,
        artifact_id,
        expected_sha256,
        expected_bytes
      ) do
    with {:ok, session} <- session_by_coop_id(coop_session_id),
         {:ok, %{"transfer_id" => transfer_id}} <-
           execute_read(client, session, "get_review_patch", %{
             "artifact_id" => artifact_id,
             "coop_session_id" => coop_session_id,
             "expected_bytes" => expected_bytes,
             "expected_sha256" => expected_sha256
           }),
         {:ok, patch} <- ArtifactTransport.fetch_review_patch(transfer_id) do
      {:ok, patch}
    else
      {:ok, _invalid} -> {:error, {:coop_protocol_error, :review_patch_transfer}}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def submit_turn(client, session_id, key, revision, prompt, schema),
    do: submit_turn_with_artifacts(client, session_id, key, revision, prompt, schema, [])

  @impl true
  def submit_turn_with_artifacts(client, session_id, key, revision, prompt, schema, artifacts) do
    submission = %{
      "contract_version" => "work-final-v1",
      "context" => %{},
      "input_artifact_refs" => [],
      "output_schema" => schema,
      "prompt" => prompt
    }

    submit_frozen_turn(client, session_id, key, revision, submission, nil, artifacts)
  end

  @impl true
  def submit_frozen_turn(
        client,
        coop_session_id,
        key,
        revision,
        submission,
        responder_binding,
        artifacts
      ) do
    with {:ok, _artifact_refs} <- exact_input_artifacts(submission, artifacts),
         :ok <- optional_responder_binding(responder_binding),
         {:ok, session} <- session_by_coop_id(coop_session_id) do
      execute(
        client,
        session,
        "submit_turn",
        submit_turn_payload(coop_session_id, revision, submission, responder_binding),
        key
      )
    end
  end

  @impl true
  def fence_submit_turn(client, session_id, key, revision, prompt, schema),
    do: fence_submit_turn_with_artifacts(client, session_id, key, revision, prompt, schema, [])

  @impl true
  def fence_submit_turn_with_artifacts(
        client,
        session_id,
        key,
        revision,
        prompt,
        schema,
        artifacts
      ) do
    submission = %{
      "contract_version" => "work-final-v1",
      "context" => %{},
      "input_artifact_refs" => [],
      "output_schema" => schema,
      "prompt" => prompt
    }

    fence_frozen_turn(client, session_id, key, revision, submission, nil, artifacts)
  end

  @impl true
  def fence_frozen_turn(
        client,
        coop_session_id,
        key,
        revision,
        submission,
        responder_binding,
        artifacts
      ) do
    with {:ok, _artifact_refs} <- exact_input_artifacts(submission, artifacts),
         :ok <- optional_responder_binding(responder_binding),
         {:ok, session} <- session_by_coop_id(coop_session_id) do
      fence_durable_operation(
        client,
        session,
        key,
        "submit_turn",
        submit_turn_payload(coop_session_id, revision, submission, responder_binding)
      )
    end
  end

  @impl true
  def get_turn(client, coop_session_id, coop_turn_id) do
    with {:ok, session} <- session_by_coop_id(coop_session_id) do
      execute_read(client, session, "get_turn", %{
        "coop_session_id" => coop_session_id,
        "coop_turn_id" => coop_turn_id
      })
    end
  end

  @impl true
  def cancel_turn(client, coop_session_id, coop_turn_id, key, revision) do
    with {:ok, session} <- session_by_coop_id(coop_session_id) do
      execute(
        client,
        session,
        "cancel_turn",
        %{
          "coop_session_id" => coop_session_id,
          "coop_turn_id" => coop_turn_id,
          "expected_revision" => revision
        },
        key
      )
    end
  end

  @impl true
  def close_session(client, coop_session_id, key, revision) do
    with {:ok, session} <- session_by_coop_id(coop_session_id) do
      execute(
        client,
        session,
        "close_session",
        %{
          "coop_session_id" => coop_session_id,
          "expected_revision" => revision
        },
        key
      )
    end
  end

  @impl true
  def plan_discard(
        client,
        coop_session_id,
        key,
        expected_revision,
        accept_dirty,
        accept_unmerged
      ) do
    with {:ok, session} <- session_by_coop_id(coop_session_id) do
      execute(
        client,
        session,
        "plan_discard",
        %{
          "accept_dirty" => accept_dirty,
          "accept_unmerged" => accept_unmerged,
          "coop_session_id" => coop_session_id,
          "expected_revision" => expected_revision
        },
        key
      )
    end
  end

  @impl true
  def discard_session(client, coop_session_id, key, plan_operation_id) do
    with {:ok, session} <- session_by_coop_id(coop_session_id) do
      execute(
        client,
        session,
        "discard_session",
        %{
          "coop_session_id" => coop_session_id,
          "plan_operation_id" => plan_operation_id
        },
        key
      )
    end
  end

  @impl true
  def validate_candidate(client, session_id, turn_id, key, sha256, verdict),
    do: validate_frozen_candidate(client, session_id, turn_id, key, 1, sha256, verdict)

  @impl true
  def validate_frozen_candidate(
        client,
        coop_session_id,
        coop_turn_id,
        key,
        attempt,
        sha256,
        verdict
      ) do
    with {:ok, session} <- session_by_coop_id(coop_session_id),
         {:ok, verdict_name, violations} <- prepare_verdict(verdict) do
      execute(
        client,
        session,
        "validate_candidate",
        %{
          "candidate_attempt" => attempt,
          "candidate_sha256" => sha256,
          "coop_session_id" => coop_session_id,
          "coop_turn_id" => coop_turn_id,
          "verdict" => verdict_name,
          "violations" => violations
        },
        key
      )
    end
  end

  @impl true
  def operation_by_key(client, key) do
    case Repo.get_by(Command, idempotency_key: key) do
      nil ->
        :not_found

      %Command{status: :succeeded, result: result} = command ->
        with :ok <- current_command_placement(command),
             {:ok, operation} <- operation_result(result) do
          reconcile_waiting_operation(client, command, operation, key)
        end

      %Command{status: status} = command when status in [:queued, :delivered, :acknowledged] ->
        with {:ok, result} <- client.bridge.await_command(command.id, client.bridge_options) do
          operation_result(result)
        end

      %Command{status: :failed, kind: kind, error: %{"code" => "invalid_command"}} = command
      when kind in ["create_session", "submit_turn"] ->
        {:ok, worker_rejected_operation(command)}

      %Command{} = command ->
        with %Session{} = session <- Repo.get(Session, command.session_id),
             {:ok, result} <-
               execute_read(client, session, "reconcile_operation", %{"operation_key" => key}) do
          operation_result(result)
        else
          nil -> {:error, {:coop_session_not_found, command.session_id}}
          {:error, _reason} = error -> error
        end
    end
  end

  @impl true
  def get_output_artifact(client, coop_session_id, coop_turn_id, artifact_id) do
    with {:ok, session} <- session_by_coop_id(coop_session_id),
         {:ok, %{"transfer_id" => transfer_id}} <-
           execute_read(client, session, "get_output_artifact", %{
             "artifact_ref" => artifact_id,
             "coop_session_id" => coop_session_id,
             "coop_turn_id" => coop_turn_id
           }),
         {:ok, artifact} <- ArtifactTransport.fetch_output(transfer_id) do
      {:ok, artifact}
    else
      {:ok, _invalid} -> {:error, {:coop_protocol_error, :output_artifact_transfer}}
      {:error, _reason} = error -> error
    end
  end

  defp execute(client, session, kind, payload, key),
    do: client.bridge.execute(session, kind, payload, key, client.bridge_options)

  defp execute_read(client, session, kind, payload) do
    key = "responder:fleet:read:#{kind}:#{Ecto.UUID.generate()}"
    execute(client, session, kind, payload, key)
  end

  defp fence_durable_operation(client, %Session{id: session_id}, key, kind, payload) do
    case Repo.get_by(Command, idempotency_key: key) do
      %Command{session_id: ^session_id, kind: ^kind, payload: durable_payload} ->
        if durable_payload_match?(kind, durable_payload, payload),
          do: operation_by_key(client, key),
          else: {:error, {:coop_worker_command_conflict, key}}

      %Command{} ->
        {:error, {:coop_worker_command_conflict, key}}

      nil ->
        {:ok,
         failed_operation(
           kind,
           "fleet-fence:#{CanonicalJSON.digest(%{"key" => key, "kind" => kind})}",
           "operation_not_enqueued",
           "The fleet mutation was not enqueued and could not reach Coop."
         )}
    end
  end

  defp database_now! do
    %{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT clock_timestamp()")
    now
  end

  defp normalize_options(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.uniq(Keyword.keys(options)) == Keyword.keys(options) do
      options |> Map.new() |> normalize_options()
    else
      {:error, {:invalid_coop_fleet_client, :options}}
    end
  end

  defp normalize_options(%{} = options) do
    keys = Map.keys(options)

    if keys -- @option_keys == [] and :workspace_ref in keys,
      do: {:ok, options},
      else: {:error, {:invalid_coop_fleet_client, :options}}
  end

  defp normalize_options(_options), do: {:error, {:invalid_coop_fleet_client, :options}}

  defp valid_workspace_ref?(workspace_ref) when is_binary(workspace_ref) do
    String.valid?(workspace_ref) and String.trim(workspace_ref) != "" and
      byte_size(workspace_ref) <= 1_024 and :binary.match(workspace_ref, <<0>>) == :nomatch
  end

  defp valid_workspace_ref?(_workspace_ref), do: false

  defp session_by_task_ref(task_ref) do
    case Repo.one(
           from(session in Session,
             where:
               session.external_ref == ^task_ref or
                 fragment("(?::jsonb ->> 'offer_ref') = ?", session.workspace_task, ^task_ref),
             order_by: [desc: session.generation],
             limit: 1
           )
         ) do
      %Session{} = session -> {:ok, session}
      nil -> {:error, {:coop_session_not_found, task_ref}}
    end
  end

  defp restore_checkpoint(%Session{generation: 1}), do: {:ok, nil}

  defp restore_checkpoint(%Session{} = session) do
    previous =
      Repo.one(
        from(previous in Session,
          where:
            previous.episode_id == ^session.episode_id and
              previous.generation < ^session.generation,
          order_by: [desc: previous.generation],
          limit: 1
        )
      )

    checkpoint =
      Repo.one(
        from(transfer in WorkspaceCheckpointTransfer,
          join: command in Command,
          on: command.id == transfer.command_id,
          join: source in Session,
          on: source.id == command.session_id,
          where:
            source.episode_id == ^session.episode_id and
              source.generation < ^session.generation and
              source.repository_ref == ^session.repository_ref and
              command.status == :succeeded,
          order_by: [desc: transfer.inserted_at, desc: transfer.id],
          limit: 1
        )
      )

    if is_nil(checkpoint) do
      if is_nil(previous) or is_nil(previous.coop_session_id),
        do: {:ok, nil},
        else: {:error, {:coop_workspace_checkpoint_required, previous.id, previous.generation}}
    else
      {:ok,
       %{
         "byte_size" => checkpoint.bundle_byte_size,
         "checkpoint_ref" => checkpoint.checkpoint_ref,
         "sha256" => checkpoint.bundle_sha256,
         "source_placement_generation" => checkpoint.placement_generation,
         "source_session_ref" => checkpoint.session_ref,
         "transfer_id" => checkpoint.id
       }}
    end
  end

  defp maybe_put_checkpoint(payload, nil), do: payload
  defp maybe_put_checkpoint(payload, checkpoint), do: Map.put(payload, "checkpoint", checkpoint)

  defp session_by_coop_id(coop_session_id) do
    case Repo.one(
           from(session in Session, where: session.coop_session_id == ^coop_session_id, limit: 1)
         ) do
      %Session{} = session -> {:ok, session}
      nil -> session_by_reconciled_coop_id(coop_session_id)
    end
  end

  defp session_by_reconciled_coop_id(coop_session_id) do
    sessions =
      Repo.all(
        from(session in Session,
          join: create in Command,
          on: create.session_id == session.id and create.kind == "create_session",
          join: reconciliation in Command,
          on:
            reconciliation.session_id == session.id and
              reconciliation.kind == "reconcile_operation" and
              fragment(
                "(?::jsonb ->> 'operation_key') = ?",
                reconciliation.payload,
                create.idempotency_key
              ),
          where:
            is_nil(session.coop_session_id) and reconciliation.status == :succeeded and
              fragment(
                "(?::jsonb ->> 'resource_id') = ?",
                reconciliation.result,
                ^coop_session_id
              ) and
              fragment("(?::jsonb ->> 'resource_type') = 'session'", reconciliation.result) and
              fragment(
                "(?::jsonb ->> 'method') = 'CreateRemoteSession'",
                reconciliation.result
              ) and
              fragment("(?::jsonb ->> 'state') = 'succeeded'", reconciliation.result),
          distinct: true,
          select: session,
          limit: 2
        )
      )

    case sessions do
      [%Session{} = session] -> {:ok, session}
      [] -> {:error, {:coop_session_not_found, coop_session_id}}
      [_first, _second] -> {:error, {:coop_session_identity_ambiguous, coop_session_id}}
    end
  end

  defp operation_result(%{"operation" => operation}) when is_map(operation), do: {:ok, operation}
  defp operation_result(%{"id" => _id} = operation), do: {:ok, operation}
  defp operation_result(_result), do: {:error, {:coop_protocol_error, :operation_resource}}

  defp reconcile_waiting_operation(
         client,
         command,
         %{"state" => state} = _operation,
         operation_key
       )
       when state in ["reserved", "running"] do
    with %Session{} = session <- Repo.get(Session, command.session_id),
         {:ok, result} <-
           execute_read(client, session, "reconcile_operation", %{
             "operation_key" => operation_key
           }) do
      operation_result(result)
    else
      nil -> {:error, {:coop_session_not_found, command.session_id}}
      {:error, _reason} = error -> error
    end
  end

  defp reconcile_waiting_operation(_client, _command, operation, _operation_key),
    do: {:ok, operation}

  defp current_command_placement(command) do
    placement = Repo.one(from(value in Placement, where: value.id == ^command.placement_id))
    %{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT clock_timestamp()")

    cond do
      placement && placement.state == :active &&
          DateTime.compare(placement.lease_expires_at, now) == :gt ->
        :ok

      placement && placement.state in [:assigning, :draining, :revoking] &&
          DateTime.compare(placement.lease_expires_at, now) == :gt ->
        {:error,
         {:coop_session_replacement_pending, command.session_id, command.placement_generation,
          placement.lease_expires_at}}

      true ->
        {:error,
         {:coop_session_replacement_required, command.session_id, command.placement_generation}}
    end
  end

  defp prepare_verdict(:accept), do: {:ok, "accept", []}

  defp prepare_verdict({:reject, violations}) when is_list(violations),
    do: {:ok, "reject", violations}

  defp prepare_verdict(_verdict), do: {:error, {:invalid_coop_request, :verdict}}

  defp exact_input_artifacts(%{"input_artifact_refs" => refs}, artifacts)
       when is_list(refs) and is_list(artifacts) do
    with {:ok, expected} <- Artifacts.coop_inputs(refs),
         true <- expected == artifacts do
      {:ok, refs}
    else
      _mismatch -> {:error, :coop_fleet_input_artifact_mismatch}
    end
  end

  defp exact_input_artifacts(_submission, _artifacts),
    do: {:error, :coop_fleet_input_artifact_mismatch}

  defp optional_responder_binding(nil), do: :ok

  defp optional_responder_binding(%{"endpoint" => endpoint, "token" => token} = binding)
       when map_size(binding) == 2 and is_binary(endpoint) and is_binary(token) do
    case URI.parse(endpoint) do
      %URI{
        scheme: "https",
        host: host,
        path: "/v1/state-tools/mcp",
        userinfo: nil,
        query: nil,
        fragment: nil
      }
      when is_binary(host) and host != "" and byte_size(endpoint) <= 2_048 ->
        if Regex.match?(~r/\A[0-9a-f]{64}[A-Za-z0-9_-]{43}\z/, token),
          do: :ok,
          else: {:error, {:invalid_coop_responder_binding, :fields}}

      _invalid ->
        {:error, {:invalid_coop_responder_binding, :fields}}
    end
  end

  defp optional_responder_binding(_binding),
    do: {:error, {:invalid_coop_responder_binding, :fields}}

  defp maybe_put_responder_binding(document, nil), do: document

  defp maybe_put_responder_binding(document, binding),
    do: Map.put(document, "responder_binding", responder_binding_descriptor(binding))

  defp create_session_payload(session, policy, task, responder_binding) do
    %{
      "authority_digest" => session.authority_digest,
      "external_ref" => task,
      "policy" => policy,
      "policy_digest" => session.policy_digest
    }
    |> maybe_put_responder_binding(responder_binding)
  end

  defp submit_turn_payload(coop_session_id, revision, submission, responder_binding) do
    %{
      "coop_session_id" => coop_session_id,
      "expected_revision" => revision,
      "submission" => submission,
      "submission_sha256" => worker_submission_digest(submission),
      "turn_ref" => submission["context"]["turn_ref"] || "logical-turn"
    }
    |> maybe_put_responder_binding(responder_binding)
  end

  defp durable_payload_match?("submit_turn", durable, expected)
       when is_map(durable) and is_map(expected) do
    submission = durable["submission"]

    Map.delete(durable, "submission_sha256") == Map.delete(expected, "submission_sha256") and
      durable["submission_sha256"] in [
        CanonicalJSON.digest(submission),
        worker_submission_digest(submission)
      ]
  end

  defp durable_payload_match?(_kind, durable, expected), do: durable == expected

  defp worker_submission_digest(submission) do
    submission
    |> CanonicalJSON.encode!()
    |> String.replace("&", "\\u0026")
    |> String.replace("<", "\\u003c")
    |> String.replace(">", "\\u003e")
    |> String.replace(<<0x2028::utf8>>, "\\u2028")
    |> String.replace(<<0x2029::utf8>>, "\\u2029")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp worker_rejected_operation(command) do
    failed_operation(
      command.kind,
      "fleet-command:#{command.id}",
      command.error["code"],
      command.error["detail"]
    )
  end

  defp failed_operation(kind, id, code, detail) do
    %{
      "error_code" => code,
      "error_detail" => detail,
      "id" => id,
      "method" => operation_method(kind),
      "state" => "failed"
    }
  end

  defp operation_method("create_session"), do: "CreateRemoteSession"
  defp operation_method("submit_turn"), do: "SubmitTurn"

  defp responder_binding_descriptor(%{"endpoint" => endpoint, "token" => token}) do
    %{"endpoint" => endpoint, "token_sha256" => StateBinding.sha256(token)}
  end
end
