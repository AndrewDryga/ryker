defmodule Responder.Work.Executor do
  @moduledoc """
  Crash-safe execution of one leased episode turn through Coop.

  Every mutating request is keyed from durable Work rows. The exact prompt,
  schema, candidate, and semantic verdict are frozen before their respective
  remote mutations. Lost responses reconcile the operation and remote resource
  rather than spending another model turn.
  """

  alias Responder.Artifacts
  alias Responder.Artifacts.Outputs
  alias Responder.Delivery.{PlatformActionCustody, Presentation}
  alias Responder.Slack.Mentions
  alias Responder.State.Records

  alias Responder.Work.{
    Cancellation,
    Custody,
    FinalPreflight,
    Measurement,
    StateBinding,
    SubmissionBuilder,
    ValidationIntent,
    Validator
  }

  @operation_waiting_states ~w(reserved running)
  @companion_name_regex ~r/\A[a-z0-9][a-z0-9_-]{0,63}\z/
  @default_state_tool_capabilities [:event_waits, :publication, :schedules]
  @git_commit_regex ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
  @state_tool_capabilities [:emisar_approvals, :event_waits, :publication, :schedules]
  @turn_waiting_states ~w(queued starting running)
  @terminal_turn_states ~w(cancelled completed failed interrupted budget_exhausted)

  @spec run(Custody.claim(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(claim, options) do
    with {:ok, settings} <- settings(options),
         :ok <- valid_claim(claim) do
      heartbeat_key = {__MODULE__, claim.turn.id, make_ref()}
      Process.put(heartbeat_key, settings.monotonic_ms.())

      try do
        settings = settings |> Map.put(:heartbeat_key, heartbeat_key) |> Map.put(:claim, claim)

        case claim.turn.status do
          :pending -> execute_turn(claim, settings)
          :cancel_pending -> execute_cancellation(claim, settings)
          :delivery_pending -> {:error, :work_delivery_requires_gateway}
          _other -> {:error, :work_turn_not_executable}
        end
      after
        Process.delete(heartbeat_key)
      end
    end
  end

  defp execute_turn(claim, settings) do
    with {:ok, claim} <- ensure_session(claim, settings),
         :ok <- require_repository_read_only(claim, settings),
         :ok <- require_project_isolation(claim, settings),
         {:ok, claim} <- ensure_state_binding(claim, settings),
         {:ok, claim} <- ensure_submission(claim, settings),
         {:ok, claim, remote_turn} <- ensure_turn(claim, settings) do
      await_turn(claim, remote_turn, settings, settings.max_polls)
    end
  end

  defp require_project_isolation(_claim, %{require_project_isolation: false}), do: :ok

  defp require_project_isolation(claim, %{require_project_isolation: true} = settings) do
    with {:ok, remote_session} <-
           api_call(settings, fn ->
             settings.api.get_session(settings.client, claim.session.coop_session_id)
           end),
         :ok <-
           exact_remote_session_state(
             claim.session,
             remote_session,
             ~w(open exhausted closed discarded)
           ) do
      if remote_session["project_env"] == false and remote_session["project_mcp"] == false,
        do: :ok,
        else: {:error, {:coop_protocol_error, :session_project_authority}}
    end
  end

  defp require_repository_read_only(_claim, %{require_repository_read_only: false}), do: :ok

  defp require_repository_read_only(claim, %{require_repository_read_only: true} = settings) do
    with {:ok, remote_session} <-
           api_call(settings, fn ->
             settings.api.get_session(settings.client, claim.session.coop_session_id)
           end),
         :ok <-
           exact_remote_session_state(
             claim.session,
             remote_session,
             ~w(open exhausted closed discarded)
           ) do
      if remote_session["repository_read_only"] == true,
        do: :ok,
        else: {:error, {:coop_protocol_error, :session_repository_write_authority}}
    end
  end

  defp ensure_state_binding(claim, %{state_tools_endpoint: nil, state_tools_secret: nil}),
    do: {:ok, claim}

  defp ensure_state_binding(claim, settings) do
    with {:ok, scope} <- StateBinding.current_scope(claim.session),
         {:ok, binding} <-
           StateBinding.derive(
             claim.session,
             claim.turn,
             scope,
             settings.state_tools_endpoint,
             settings.state_tools_secret
           ),
         {:ok, turn} <-
           Custody.bind_state_tools(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             binding.endpoint,
             binding.token_sha256
           ) do
      {:ok, claim |> Map.put(:turn, turn) |> Map.put(:state_binding, binding)}
    end
  end

  defp ensure_submission(%{turn: %{submission: nil}} = claim, settings) do
    with {:ok, workspace} <- session_workspace(claim, settings),
         submission_options <-
           [state_tool_capabilities: settings.state_tool_capabilities, workspace: workspace]
           |> maybe_submission_option(:platform_tools, settings.platform_tools),
         {:ok, submission} <-
           SubmissionBuilder.build(claim, submission_options),
         {:ok, turn} <-
           Custody.freeze_submission(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             submission
           ) do
      {:ok, %{claim | turn: turn}}
    end
  end

  defp ensure_submission(%{turn: %{submission: submission}} = claim, _settings)
       when is_map(submission),
       do: {:ok, claim}

  defp ensure_submission(_claim, _settings), do: {:error, :work_submission_missing}

  defp maybe_submission_option(options, _key, nil), do: options
  defp maybe_submission_option(options, key, value), do: Keyword.put(options, key, value)

  defp session_workspace(claim, settings) do
    with {:ok, remote_session} <-
           api_call(settings, fn ->
             settings.api.get_session(settings.client, claim.session.coop_session_id)
           end),
         :ok <-
           exact_remote_session_state(
             claim.session,
             remote_session,
             ~w(open exhausted closed discarded)
           ),
         {:ok, primary} <- primary_workspace(claim.session, remote_session),
         {:ok, companions} <- companion_workspaces(Map.get(remote_session, "companions", [])),
         :ok <- required_workspaces(companions, settings.workspace_requirements),
         {:ok, freshness} <- repository_freshness(remote_session, primary, companions) do
      {:ok, %{"companions" => companions, "freshness" => freshness, "primary" => primary}}
    end
  end

  defp primary_workspace(session, %{
         "base_commit" => base_commit,
         "repository_read_only" => read_only
       })
       when is_boolean(read_only) do
    name = session.repository_ref || "primary"

    if reference?(name) and git_commit?(base_commit) do
      {:ok,
       %{
         "base_commit" => base_commit,
         "name" => name,
         "path" => ".",
         "read_only" => read_only
       }}
    else
      {:error, {:coop_protocol_error, :session_workspace}}
    end
  end

  defp primary_workspace(_session, _remote_session),
    do: {:error, {:coop_protocol_error, :session_workspace}}

  defp companion_workspaces(companions) when is_list(companions) and length(companions) <= 32 do
    result =
      Enum.reduce_while(companions, {:ok, []}, fn companion, {:ok, prepared} ->
        case companion_workspace(companion) do
          {:ok, value} -> {:cont, {:ok, [value | prepared]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)

    case result do
      {:ok, prepared} ->
        sorted = Enum.sort_by(prepared, & &1["name"])
        names = Enum.map(sorted, & &1["name"])

        if names == Enum.uniq(names),
          do: {:ok, sorted},
          else: {:error, {:coop_protocol_error, :session_workspace}}

      {:error, _reason} = error ->
        error
    end
  end

  defp companion_workspaces(_companions),
    do: {:error, {:coop_protocol_error, :session_workspace}}

  defp companion_workspace(
         %{
           "base_commit" => base_commit,
           "name" => name,
           "path" => path
         } = companion
       )
       when map_size(companion) == 3 do
    if is_binary(name) and Regex.match?(@companion_name_regex, name) and
         path == "/coop/repositories/#{name}" and git_commit?(base_commit) do
      {:ok,
       %{
         "base_commit" => base_commit,
         "name" => name,
         "path" => path,
         "read_only" => true
       }}
    else
      {:error, {:coop_protocol_error, :session_workspace}}
    end
  end

  defp companion_workspace(_companion),
    do: {:error, {:coop_protocol_error, :session_workspace}}

  defp required_workspaces(_companions, []), do: :ok

  defp required_workspaces(companions, requirements) do
    available = Map.new(companions, &{&1["name"], &1["base_commit"]})

    if Enum.all?(requirements, fn %{"base_commit" => base_commit, "name" => name} ->
         Map.get(available, name) == base_commit
       end),
       do: :ok,
       else: {:error, {:coop_protocol_error, :session_workspace}}
  end

  defp repository_freshness(remote_session, primary, companions) do
    case {
      Map.get(remote_session, "repository_freshness_status"),
      Map.get(remote_session, "repository_freshness")
    } do
      {"recorded", receipts} when is_list(receipts) and length(receipts) in 1..34 ->
        with {:ok, receipts} <- repository_freshness_receipts(receipts),
             :ok <- exact_repository_receipts(receipts, remote_session, primary, companions) do
          {:ok, %{"owner" => "coop", "repositories" => receipts, "status" => "recorded"}}
        end

      _invalid ->
        {:error, {:coop_protocol_error, :repository_freshness}}
    end
  end

  defp repository_freshness_receipts(receipts) do
    Enum.reduce_while(receipts, {:ok, []}, fn receipt, {:ok, prepared} ->
      case repository_freshness_receipt(receipt) do
        {:ok, receipt} -> {:cont, {:ok, [receipt | prepared]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, prepared} ->
        prepared = Enum.reverse(prepared)
        names = Enum.map(prepared, & &1["name"])

        if names == Enum.uniq(names),
          do: {:ok, prepared},
          else: {:error, {:coop_protocol_error, :repository_freshness}}

      {:error, _reason} = error ->
        error
    end
  end

  defp repository_freshness_receipt(
         %{
           "fetched_at" => fetched_at,
           "name" => name,
           "remote_identity" => remote_identity,
           "requested_revision" => requested_revision,
           "resolved_revision" => resolved_revision,
           "stale_base_status" => stale_base_status,
           "version" => 2
         } = receipt
       )
       when map_size(receipt) in 7..9 and
              stale_base_status in ~w(current stale unknown not_applicable) do
    stale_base_revision = Map.get(receipt, "stale_base_revision")
    workspace_base_revision = Map.get(receipt, "workspace_base_revision")

    with true <- repository_name?(name),
         true <- bounded_text?(remote_identity, 256),
         true <- bounded_text?(requested_revision, 512),
         true <- git_commit?(resolved_revision),
         true <- is_nil(workspace_base_revision) or git_commit?(workspace_base_revision),
         {:ok, fetched_at} <- repository_timestamp(fetched_at),
         :ok <- stale_base_receipt(stale_base_status, stale_base_revision, resolved_revision) do
      {:ok,
       %{
         "fetched_at" => fetched_at,
         "name" => name,
         "remote_identity" => remote_identity,
         "requested_revision" => requested_revision,
         "resolved_revision" => resolved_revision,
         "stale_base_revision" => stale_base_revision,
         "stale_base_status" => stale_base_status,
         "version" => 2,
         "workspace_base_revision" => workspace_base_revision
       }}
    else
      _invalid -> {:error, {:coop_protocol_error, :repository_freshness}}
    end
  end

  defp repository_freshness_receipt(_receipt),
    do: {:error, {:coop_protocol_error, :repository_freshness}}

  defp exact_repository_receipts(receipts, remote_session, primary, companions) do
    by_name = Map.new(receipts, &{&1["name"], &1})

    expected_names =
      ["primary" | Enum.map(companions, & &1["name"])] ++ pull_request_names(remote_session)

    valid =
      Map.keys(by_name) |> Enum.sort() == Enum.sort(expected_names) and
        primary_receipt_matches?(by_name["primary"], remote_session, primary) and
        Enum.all?(companions, fn companion ->
          receipt = by_name[companion["name"]]

          receipt["resolved_revision"] == companion["base_commit"] and
            is_nil(receipt["workspace_base_revision"])
        end) and pull_request_receipt_matches?(by_name, remote_session)

    if valid, do: :ok, else: {:error, {:coop_protocol_error, :repository_freshness}}
  end

  defp primary_receipt_matches?(receipt, remote_session, primary) when is_map(receipt) do
    receipt["workspace_base_revision"] == primary["base_commit"] and
      (pull_request_names(remote_session) == ["pull_request"] or
         receipt["resolved_revision"] == primary["base_commit"])
  end

  defp primary_receipt_matches?(_receipt, _remote_session, _primary), do: false

  defp pull_request_receipt_matches?(by_name, %{
         "pull_request" => %{"head_commit" => head_commit}
       }) do
    receipt = by_name["pull_request"]

    is_map(receipt) and receipt["resolved_revision"] == head_commit and
      is_nil(receipt["workspace_base_revision"])
  end

  defp pull_request_receipt_matches?(_by_name, _remote_session), do: true

  defp pull_request_names(%{"pull_request" => %{"head_commit" => head_commit}})
       when is_binary(head_commit),
       do: ["pull_request"]

  defp pull_request_names(_remote_session), do: []

  defp repository_name?(name),
    do: name in ["primary", "pull_request"] or companion_name?(name)

  defp companion_name?(name),
    do: is_binary(name) and Regex.match?(@companion_name_regex, name)

  defp bounded_text?(value, maximum) do
    is_binary(value) and String.valid?(value) and byte_size(value) in 1..maximum and
      :binary.match(value, <<0>>) == :nomatch
  end

  defp repository_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, DateTime.to_iso8601(datetime)}
      _invalid -> {:error, :invalid_timestamp}
    end
  end

  defp repository_timestamp(_value), do: {:error, :invalid_timestamp}

  defp stale_base_receipt("current", revision, resolved_revision)
       when revision == resolved_revision,
       do: :ok

  defp stale_base_receipt("stale", revision, resolved_revision)
       when revision != resolved_revision,
       do: if(git_commit?(revision), do: :ok, else: :error)

  defp stale_base_receipt(status, nil, _resolved_revision)
       when status in ~w(unknown not_applicable),
       do: :ok

  defp stale_base_receipt(_status, _revision, _resolved_revision), do: :error

  defp ensure_session(%{session: %{coop_session_id: id}} = claim, settings)
       when is_binary(id) do
    case api_call(settings, fn -> settings.api.get_session(settings.client, id) end) do
      {:ok, remote_session} ->
        with :ok <-
               exact_remote_session_state(
                 claim.session,
                 remote_session,
                 ~w(open exhausted closed discarded)
               ) do
          use_or_rotate_session(claim, remote_session, settings)
        end

      {:error, {:coop_session_replacement_required, _session_id, _generation}} ->
        replace_lost_session(claim, settings)

      {:error, _reason} = error ->
        error
    end
  end

  defp ensure_session(claim, settings) do
    key = create_key(claim.session)

    result =
      with :ok <- new_session_repository_capability(claim, settings) do
        case operation_by_key(settings, key) do
          :not_found -> create_session(claim, key, settings)
          {:ok, operation} -> bind_session_from_operation(claim, operation, key, settings)
          {:error, _reason} = error -> error
        end
      end

    case result do
      {:error, {:coop_session_replacement_required, _session_id, _generation}} ->
        replace_lost_session(claim, settings)

      other ->
        other
    end
  end

  defp new_session_repository_capability(%{session: %{repository_ref: nil}}, _settings), do: :ok

  defp new_session_repository_capability(
         %{session: %{repository_ref: repository_ref}} = claim,
         settings
       )
       when is_binary(repository_ref),
       do: repository_freshness_v2_capability(claim, settings)

  defp replace_lost_session(claim, settings) do
    with {:ok, rotated} <-
           Custody.replace_session_after_placement_loss(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.session.generation
           ),
         {:ok, rebound} <-
           ensure_state_binding(
             %{claim | session: rotated.session, turn: rotated.turn},
             settings
           ) do
      ensure_session(rebound, settings)
    end
  end

  defp use_or_rotate_session(%{turn: %{coop_turn_id: id}} = claim, _remote, _settings)
       when is_binary(id),
       do: {:ok, claim}

  defp use_or_rotate_session(claim, %{"state" => "open"} = remote, settings) do
    if legacy_repository_freshness?(remote) do
      with :ok <- repository_freshness_v2_capability(claim, settings) do
        rotate_session(claim, settings)
      end
    else
      {:ok, claim}
    end
  end

  defp use_or_rotate_session(claim, %{"state" => state}, settings)
       when state in ~w(exhausted closed discarded) do
    rotate_session(claim, settings)
  end

  defp use_or_rotate_session(_claim, _remote, _settings),
    do: {:error, {:coop_protocol_error, :session_state}}

  defp rotate_session(claim, settings) do
    with {:ok, rotated} <-
           Custody.rotate_session(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.session.generation
           ),
         {:ok, rebound} <-
           ensure_state_binding(
             %{claim | session: rotated.session, turn: rotated.turn},
             settings
           ) do
      ensure_session(rebound, settings)
    end
  end

  defp legacy_repository_freshness?(%{"repository_freshness_status" => "unavailable"}),
    do: true

  defp legacy_repository_freshness?(%{
         "repository_freshness_status" => "recorded",
         "repository_freshness" => receipts
       })
       when is_list(receipts),
       do: Enum.any?(receipts, &(is_map(&1) and Map.get(&1, "version") == 1))

  defp legacy_repository_freshness?(_remote), do: false

  defp repository_freshness_v2_capability(claim, settings) do
    with {:ok, capability_call} <- repository_freshness_capability_call(claim, settings) do
      settings
      |> api_call(capability_call)
      |> validate_repository_freshness_capability()
    end
  end

  defp repository_freshness_capability_call(claim, settings) do
    cond do
      function_exported?(settings.api, :capabilities, 2) ->
        {:ok, fn -> settings.api.capabilities(settings.client, claim.session) end}

      function_exported?(settings.api, :capabilities, 1) ->
        {:ok, fn -> settings.api.capabilities(settings.client) end}

      true ->
        {:error, {:coop_upgrade_required, :repository_freshness_v2}}
    end
  end

  defp validate_repository_freshness_capability(
         {:ok, %{"repository_freshness_receipt_versions" => versions}}
       ) do
    if capability_versions?(versions) and 2 in versions,
      do: :ok,
      else: {:error, {:coop_upgrade_required, :repository_freshness_v2}}
  end

  defp validate_repository_freshness_capability({:ok, _invalid}),
    do: {:error, {:coop_upgrade_required, :repository_freshness_v2}}

  defp validate_repository_freshness_capability({:error, {:coop_error, 404, _code, _detail}}),
    do: {:error, {:coop_upgrade_required, :repository_freshness_v2}}

  defp validate_repository_freshness_capability({:error, _reason} = error), do: error

  defp capability_versions?(versions)
       when is_list(versions) and versions != [] and
              length(versions) <= 16 do
    versions == Enum.sort(Enum.uniq(versions)) and
      Enum.all?(versions, &(is_integer(&1) and &1 > 0 and &1 <= 65_535))
  end

  defp capability_versions?(_versions), do: false

  defp create_session(claim, key, settings) do
    task = claim.session.external_ref

    case mutation_call(settings, :create_session, key, fn ->
           create_remote_session(settings, claim, key, task)
         end) do
      {:ok, %{"session" => remote_session}} when is_map(remote_session) ->
        case bind_session(claim, remote_session) do
          {:ok, _claim} = success -> success
          {:error, reason} -> reconcile_create_response(claim, key, reason, settings)
        end

      {:ok, %{"operation" => operation}} when is_map(operation) ->
        bind_session_from_operation(claim, operation, key, settings)

      {:ok, _response} ->
        reconcile_create_response(claim, key, :create_session_response, settings)

      {:error, _reason} = error ->
        reconcile_after_transport(error, key, settings, fn operation ->
          bind_session_from_operation(claim, operation, key, settings)
        end)
    end
  end

  defp reconcile_create_response(claim, key, reason, settings) do
    reconcile_after_transport(ambiguous_mutation(:create_session, reason), key, settings, fn
      operation -> bind_session_from_operation(claim, operation, key, settings)
    end)
  end

  defp bind_session_from_operation(claim, operation, key, settings) do
    case operation_resource(
           operation,
           "session",
           "CreateRemoteSession",
           key,
           settings,
           settings.max_polls
         ) do
      {:ok, session_id} ->
        fetch_and_bind_session(claim, session_id, settings)

      {:confirmed_failed, reason} ->
        with {:ok, _session} <-
               Custody.advance_session_create(
                 claim.episode.id,
                 claim.turn.turn_ref,
                 claim.lease_ref,
                 claim.session.create_generation
               ) do
          {:error, {:work_generation_spent, :session_create, reason}}
        end

      {:uncertain, reason} ->
        {:error, {:work_execution_blocked, reason}}

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_and_bind_session(claim, session_id, settings) do
    with {:ok, remote_session} <-
           api_call(settings, fn -> settings.api.get_session(settings.client, session_id) end) do
      bind_session(claim, remote_session)
    end
  end

  defp bind_session(claim, %{"id" => remote_session_id} = remote_session)
       when is_binary(remote_session_id) do
    with :ok <- exact_remote_session(claim.session, remote_session),
         {:ok, session} <-
           Custody.bind_session(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.session.generation,
             claim.session.create_generation,
             remote_session_id
           ) do
      {:ok, %{claim | session: session}}
    end
  end

  defp bind_session(_claim, _remote_session),
    do: {:error, {:coop_protocol_error, :session_resource}}

  defp ensure_turn(%{turn: %{coop_turn_id: turn_id}} = claim, settings)
       when is_binary(turn_id) do
    with {:ok, remote_turn} <- fetch_turn(claim, turn_id, settings) do
      {:ok, claim, remote_turn}
    end
  end

  defp ensure_turn(claim, settings) do
    key = turn_key(claim.turn)

    case operation_by_key(settings, key) do
      :not_found -> submit_turn(claim, key, settings)
      {:ok, operation} -> bind_turn_from_operation(claim, operation, key, settings)
      {:error, _reason} = error -> error
    end
  end

  defp submit_turn(claim, key, settings) do
    with {:ok, artifacts} <- input_artifacts(claim),
         {:ok, remote_session} <-
           api_call(settings, fn ->
             settings.api.get_session(settings.client, claim.session.coop_session_id)
           end),
         :ok <- exact_remote_session(claim.session, remote_session),
         {:ok, revision} <- revision(remote_session),
         response <-
           mutation_call(settings, :submit_turn, key, revision, fn ->
             submit_frozen_turn(settings, claim, key, revision, artifacts)
           end) do
      handle_submit_response(response, claim, key, settings)
    end
  end

  defp handle_submit_response({:ok, %{"turn" => remote_turn}}, claim, key, settings)
       when is_map(remote_turn) do
    case bind_turn(claim, remote_turn) do
      {:ok, _claim, _turn} = success -> success
      {:error, reason} -> reconcile_submit_response(claim, key, reason, settings)
    end
  end

  defp handle_submit_response({:ok, %{"operation" => operation}}, claim, key, settings)
       when is_map(operation),
       do: bind_turn_from_operation(claim, operation, key, settings)

  defp handle_submit_response({:ok, _response}, claim, key, settings),
    do: reconcile_submit_response(claim, key, :submit_turn_response, settings)

  defp handle_submit_response(
         {:error, {:coop_error, 409, "revision_conflict", _detail} = reason},
         claim,
         _key,
         _settings
       ),
       do: spend_submit_generation(claim, reason)

  defp handle_submit_response({:error, _reason} = error, claim, key, settings) do
    reconcile_after_transport(error, key, settings, fn operation ->
      bind_turn_from_operation(claim, operation, key, settings)
    end)
  end

  defp reconcile_submit_response(claim, key, reason, settings) do
    reconcile_after_transport(ambiguous_mutation(:submit_turn, reason), key, settings, fn
      operation -> bind_turn_from_operation(claim, operation, key, settings)
    end)
  end

  defp bind_turn_from_operation(claim, operation, key, settings) do
    case operation_resource(
           operation,
           "turn",
           "SubmitTurn",
           key,
           settings,
           settings.max_polls
         ) do
      {:ok, turn_id} ->
        fetch_and_bind_turn(claim, turn_id, settings)

      {:confirmed_failed, reason} ->
        spend_submit_generation(claim, reason)

      {:uncertain, reason} ->
        {:error, {:work_execution_blocked, reason}}

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_and_bind_turn(claim, turn_id, settings) do
    with {:ok, remote_turn} <- fetch_turn(claim, turn_id, settings) do
      bind_turn(claim, remote_turn)
    end
  end

  defp bind_turn(claim, %{"id" => remote_turn_id} = remote_turn)
       when is_binary(remote_turn_id) do
    with :ok <-
           exact_remote_turn(
             remote_turn,
             claim.session.coop_session_id,
             nil,
             StateBinding.binding_digest(claim.turn)
           ),
         {:ok, turn} <-
           Custody.bind_turn(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.session.generation,
             claim.turn.submit_generation,
             remote_turn_id
           ) do
      {:ok, %{claim | turn: turn}, remote_turn}
    end
  end

  defp bind_turn(_claim, _remote_turn),
    do: {:error, {:coop_protocol_error, :turn_resource}}

  defp spend_submit_generation(claim, reason) do
    with {:ok, _turn} <-
           Custody.advance_turn_submit(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.turn.submit_generation
           ) do
      {:error, {:work_generation_spent, :turn_submit, reason}}
    end
  end

  defp await_turn(
         claim,
         %{"state" => "awaiting_validation", "candidate" => candidate} = remote_turn,
         settings,
         left
       )
       when is_map(candidate) do
    with {:ok, artifacts} <- output_artifact_metadata(remote_turn) do
      handle_candidate(claim, candidate, artifacts, settings, left)
    end
  end

  defp await_turn(claim, %{"state" => "completed"} = remote_turn, settings, _left) do
    accept_completed(claim, remote_turn, settings)
  end

  defp await_turn(claim, %{"state" => state}, settings, left)
       when state in @turn_waiting_states and left > 0 do
    with :ok <- pause(settings),
         {:ok, remote_turn} <- fetch_bound_turn(claim, settings) do
      await_turn(claim, remote_turn, settings, left - 1)
    end
  end

  defp await_turn(_claim, %{"state" => state}, _settings, 0)
       when state in @turn_waiting_states,
       do: {:error, {:work_poll_window_elapsed, :turn}}

  defp await_turn(_claim, %{"state" => state} = turn, _settings, _left)
       when state in ~w(failed interrupted budget_exhausted cancelled) do
    {:error, {:work_turn_terminal, state, turn["error_code"], turn["error_detail"]}}
  end

  defp await_turn(_claim, _turn, _settings, _left),
    do: {:error, {:coop_protocol_error, :turn_state}}

  defp handle_candidate(claim, candidate, artifacts, settings, left) do
    with {:ok, message, sha256, attempt} <- candidate_fields(candidate),
         {:ok, turn} <-
           Custody.stage_candidate(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.turn.candidate_sha256,
             claim.turn.candidate_attempt,
             message,
             sha256,
             attempt
           ),
         claim = %{claim | turn: turn},
         {:ok, claim} <-
           ensure_validation_intent(claim, message, sha256, attempt, artifacts, settings),
         {:ok, remote_turn} <- validate_candidate(claim, settings) do
      await_turn(claim, remote_turn, settings, left)
    end
  end

  defp ensure_validation_intent(
         %{turn: %{validation_intent: intent}} = claim,
         _message,
         _sha,
         _attempt,
         _artifacts,
         _settings
       )
       when is_map(intent),
       do: {:ok, claim}

  defp ensure_validation_intent(claim, message, sha256, attempt, artifacts, settings) do
    with {:ok, validation_context} <- validation_context(claim, artifacts, settings) do
      case Validator.validate(message, validation_context, settings.now.()) do
        {:accept, %{final: final, result: result}} ->
          prepare_accepted_validation(
            claim,
            message,
            sha256,
            attempt,
            artifacts,
            final,
            result
          )

        {:reject, violations} ->
          prepare_validation(claim, sha256, attempt, {:reject, violations}, nil)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp prepare_accepted_validation(claim, message, sha256, attempt, artifacts, final, result) do
    case Presentation.validate(claim.episode, claim.turn.id, final) do
      :ok ->
        ensure_final_preflight(claim, message, sha256, attempt, artifacts, result)

      {:error, {:invalid_delivery_presentation, reason}} ->
        prepare_validation(
          claim,
          sha256,
          attempt,
          {:reject, [presentation_violation(reason)]},
          nil
        )
    end
  end

  defp ensure_final_preflight(
         %{turn: %{state_tools_endpoint: endpoint}} = claim,
         message,
         sha256,
         attempt,
         artifacts,
         result
       )
       when is_binary(endpoint) do
    with {:ok, candidate} <- decode_candidate(message),
         candidate_sha256 = FinalPreflight.candidate_sha256(candidate),
         {:ok, _turn} <-
           Custody.verify_final_preflight(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             candidate_sha256,
             Outputs.refs(artifacts)
           ) do
      prepare_validation(claim, sha256, attempt, :accept, result)
    else
      {:error, :work_final_preflight_required} ->
        prepare_validation(
          claim,
          sha256,
          attempt,
          {:reject,
           [
             "Call validate_final with this exact candidate after completing all state-tool writes, then return the accepted candidate unchanged."
           ]},
          nil
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp ensure_final_preflight(claim, _message, sha256, attempt, _artifacts, result),
    do: prepare_validation(claim, sha256, attempt, :accept, result)

  defp presentation_violation(reason) do
    "The final response cannot be rendered safely for this destination: #{inspect(reason, limit: 8, printable_limit: 256)}"
  end

  defp decode_candidate(message) do
    case Jason.decode(message) do
      {:ok, %{} = candidate} -> {:ok, candidate}
      _invalid -> {:error, {:coop_protocol_error, :candidate}}
    end
  end

  defp prepare_validation(claim, sha256, attempt, verdict, result) do
    with {:ok, turn} <-
           Custody.prepare_validation(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             sha256,
             attempt,
             verdict,
             result
           ) do
      {:ok, %{claim | turn: turn}}
    end
  end

  defp validate_candidate(claim, settings) do
    intent = claim.turn.validation_intent
    verdict = validation_verdict(intent)
    key = validation_key(claim.turn, verdict)

    case operation_by_key(settings, key) do
      :not_found -> mutate_validation(claim, key, verdict, settings)
      {:ok, operation} -> validation_from_operation(claim, operation, key, settings)
      {:error, _reason} = error -> error
    end
  end

  defp mutate_validation(claim, key, verdict, settings) do
    case mutation_call(settings, :validate_candidate, key, fn ->
           validate_frozen_candidate(settings, claim, key, verdict)
         end) do
      {:ok, %{"turn" => remote_turn}} when is_map(remote_turn) ->
        case exact_remote_turn(
               remote_turn,
               claim.session.coop_session_id,
               claim.turn.coop_turn_id,
               StateBinding.binding_digest(claim.turn)
             ) do
          :ok -> {:ok, remote_turn}
          {:error, reason} -> reconcile_validation_response(claim, key, reason, settings)
        end

      {:ok, %{"operation" => operation}} when is_map(operation) ->
        validation_from_operation(claim, operation, key, settings)

      {:ok, _response} ->
        reconcile_validation_response(claim, key, :validation_response, settings)

      {:error, {:coop_error, 503, "session_cleanup_error", _detail} = reason} ->
        recover_validation_cleanup(claim, reason, settings)

      {:error, {:coop_error, 409, "operation_uncertain", _detail} = reason} ->
        reconcile_uncertain_validation(claim, reason, settings)

      {:error, _reason} = error ->
        reconcile_after_transport(error, key, settings, fn operation ->
          validation_from_operation(claim, operation, key, settings)
        end)
    end
  end

  defp reconcile_validation_response(claim, key, reason, settings) do
    reconcile_after_transport(ambiguous_mutation(:validate_candidate, reason), key, settings, fn
      operation -> validation_from_operation(claim, operation, key, settings)
    end)
  end

  defp validation_from_operation(claim, operation, key, settings) do
    case operation_resource(
           operation,
           "turn_validation",
           "ValidateTurnCandidate",
           key,
           settings,
           settings.max_polls
         ) do
      {:ok, turn_id} when turn_id == claim.turn.coop_turn_id ->
        fetch_bound_turn(claim, settings)

      {:ok, _turn_id} ->
        {:error, {:coop_protocol_error, :turn_identity}}

      {:confirmed_failed, reason} ->
        if validation_cleanup_failure?(reason),
          do: recover_validation_cleanup(claim, reason, settings),
          else: {:error, {:work_execution_blocked, reason}}

      {:uncertain, reason} ->
        reconcile_uncertain_validation(claim, reason, settings)

      {:error, _reason} = error ->
        error
    end
  end

  defp spend_validation_generation(claim, reason) do
    with {:ok, _turn} <-
           Custody.advance_validation(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.turn.candidate_sha256,
             claim.turn.candidate_attempt,
             claim.turn.validation_generation
           ) do
      {:error, {:work_generation_spent, :validation, reason}}
    end
  end

  defp recover_validation_cleanup(claim, reason, settings) do
    with {:ok, remote_turn} <- fetch_bound_turn(claim, settings) do
      recover_validation_state(remote_turn, claim, reason)
    end
  end

  defp recover_validation_state(
         %{"state" => "awaiting_validation", "candidate" => candidate},
         claim,
         reason
       )
       when is_map(candidate) do
    recover_validation_candidate(candidate_fields(candidate), claim, reason)
  end

  defp recover_validation_state(_remote_turn, _claim, reason),
    do: {:error, {:work_execution_blocked, reason}}

  defp recover_validation_candidate(
         {:ok, _message, sha256, attempt},
         claim,
         reason
       )
       when sha256 == claim.turn.candidate_sha256 and attempt == claim.turn.candidate_attempt,
       do: spend_validation_generation(claim, reason)

  defp recover_validation_candidate(_candidate, _claim, reason),
    do: {:error, {:work_execution_blocked, reason}}

  defp validation_cleanup_failure?({:coop_operation_failed, "session_cleanup_error", _detail}),
    do: true

  defp validation_cleanup_failure?(_reason), do: false

  defp reconcile_uncertain_validation(claim, reason, settings) do
    with {:ok, remote_turn} <- fetch_bound_turn(claim, settings) do
      uncertain_validation_state(remote_turn, claim, reason)
    end
  end

  defp uncertain_validation_state(%{"state" => "completed"} = turn, _claim, _reason),
    do: {:ok, turn}

  defp uncertain_validation_state(
         %{"state" => "awaiting_validation", "candidate" => candidate} = turn,
         claim,
         reason
       )
       when is_map(candidate) do
    uncertain_validation_candidate(candidate_fields(candidate), turn, claim, reason)
  end

  defp uncertain_validation_state(
         %{"state" => state} = turn,
         %{turn: %{validation_intent: %{"verdict" => "reject"}}},
         _reason
       )
       when state in @turn_waiting_states,
       do: {:ok, turn}

  defp uncertain_validation_state(%{"state" => state} = turn, _claim, _reason)
       when state in @terminal_turn_states,
       do: {:ok, turn}

  defp uncertain_validation_state(_turn, _claim, reason),
    do: {:error, {:work_execution_blocked, reason}}

  defp uncertain_validation_candidate(
         {:ok, _message, sha256, attempt},
         turn,
         claim,
         _reason
       )
       when sha256 != claim.turn.candidate_sha256 or attempt != claim.turn.candidate_attempt,
       do: {:ok, turn}

  defp uncertain_validation_candidate(_candidate, _turn, _claim, reason),
    do: {:error, {:work_execution_blocked, reason}}

  defp accept_completed(claim, remote_turn, settings) do
    with {:ok, message, sha256, attempt, receipt} <- completed_fields(remote_turn),
         :ok <- completed_matches(claim.turn, message, sha256, attempt),
         {:ok, remote_session} <- accepted_remote_session(claim, settings),
         {:ok, artifacts} <- output_artifact_metadata(remote_turn),
         {:ok, _stored} <- retain_selected_artifacts(claim, artifacts, settings),
         {:ok, checkpoint} <- checkpoint_accepted_workspace(claim, remote_session, settings),
         :ok <- ensure_checkpoint_publication_offer(claim, checkpoint),
         {:ok, accepted} <-
           Custody.accept_result(
             claim.episode.id,
             claim.episode.key,
             claim.turn.turn_ref,
             claim.lease_ref,
             sha256,
             claim.turn.candidate_attempt,
             receipt,
             Measurement.prepare(remote_turn, remote_session)
           ) do
      {:ok,
       %{
         episode: accepted.episode,
         remote_session_id: claim.session.coop_session_id,
         remote_turn_id: claim.turn.coop_turn_id,
         status: :accepted,
         turn: accepted.turn
       }}
    end
  end

  defp checkpoint_accepted_workspace(
         %{session: %{workspace_task: task, repository_ref: repository_ref}} = claim,
         remote_session,
         settings
       )
       when is_map(task) and is_binary(repository_ref) do
    checkpoint_accepted_workspace(
      claim,
      remote_session,
      settings,
      function_exported?(settings.api, :checkpoint_workspace, 4)
    )
  end

  defp checkpoint_accepted_workspace(_claim, _remote_session, _settings), do: {:ok, nil}

  defp checkpoint_accepted_workspace(claim, remote_session, settings, true) do
    with {:ok, expected_revision} <- revision(remote_session),
         {:ok, %{"transfer_id" => transfer_id}}
         when is_binary(transfer_id) and transfer_id != "" <-
           api_call(settings, fn ->
             settings.api.checkpoint_workspace(
               settings.client,
               claim.session.coop_session_id,
               checkpoint_key(claim.turn),
               expected_revision
             )
           end) do
      {:ok, %{"transfer_id" => transfer_id}}
    else
      {:ok, _invalid} -> {:error, {:coop_protocol_error, :workspace_checkpoint}}
      {:error, _reason} = error -> error
    end
  end

  defp checkpoint_accepted_workspace(_claim, _remote_session, _settings, false),
    do: {:error, {:invalid_work_executor, :workspace_checkpoint_api}}

  defp ensure_checkpoint_publication_offer(_claim, nil), do: :ok

  defp ensure_checkpoint_publication_offer(
         %{session: %{workspace_task: task}, turn: turn},
         %{"transfer_id" => transfer_id}
       )
       when is_map(task) and is_binary(transfer_id) do
    with {:ok, result} <- ValidationIntent.result(turn.validation_intent),
         {:ok, body} <- publication_offer_body(result),
         {:ok, _record} <-
           Records.create(
             Records.token(turn),
             "host:publication:ready",
             "publication_offer",
             %{
               "body" => body,
               "title" => task["title"]
             }
           ) do
      :ok
    end
  end

  defp ensure_checkpoint_publication_offer(_claim, _checkpoint),
    do: {:error, {:coop_protocol_error, :workspace_checkpoint}}

  defp publication_offer_body(%{delivery_document: %{"message" => message}})
       when is_binary(message) do
    body = message |> String.trim() |> String.byte_slice(0, 8_000)

    if body == "",
      do: {:error, {:coop_protocol_error, :publication_offer}},
      else: {:ok, body}
  end

  defp publication_offer_body(_result),
    do: {:error, {:coop_protocol_error, :publication_offer}}

  defp accepted_remote_session(claim, settings) do
    with {:ok, remote_session} <-
           api_call(settings, fn ->
             settings.api.get_session(settings.client, claim.session.coop_session_id)
           end),
         :ok <-
           exact_remote_session_state(
             claim.session,
             remote_session,
             ~w(open exhausted closed discarded)
           ) do
      {:ok, remote_session}
    end
  end

  defp completed_matches(turn, message, sha256, attempt) do
    cond do
      turn.validation_intent == nil or turn.validation_intent["verdict"] != "accept" ->
        {:error, {:coop_protocol_error, :completed_without_accept_intent}}

      turn.candidate_attempt != attempt ->
        {:error, {:coop_protocol_error, :validation_attempt}}

      turn.candidate != message or turn.candidate_sha256 != sha256 ->
        {:error, {:coop_protocol_error, :validated_candidate_mismatch}}

      true ->
        :ok
    end
  end

  defp execute_cancellation(claim, settings) do
    key = Cancellation.operation_key(claim.turn.id, claim.turn.cancel_generation)

    with {:ok, claim} <- ensure_state_binding(claim, settings),
         {:ok, claim} <- reconcile_cancellation_session(claim, settings),
         {:ok, claim, remote_turn} <- reconcile_cancellation_turn(claim, settings) do
      continue_cancellation(remote_turn, claim, key, settings)
    end
  end

  defp continue_cancellation(:not_created, claim, _key, settings),
    do: settle_absent_cancellation(claim, settings)

  defp continue_cancellation(%{} = turn, claim, key, settings) do
    if terminal_turn?(turn),
      do: settle_remote_cancellation(claim, nil, turn, settings),
      else: cancel_remote_turn(claim, key, turn, settings)
  end

  defp reconcile_cancellation_session(
         %{session: %{coop_session_id: session_id}} = claim,
         _settings
       )
       when is_binary(session_id),
       do: {:ok, claim}

  defp reconcile_cancellation_session(claim, settings) do
    key = create_key(claim.session)

    if frozen_remote_operation?(claim.turn, "create_session", key) do
      fence_cancellation_session_create(claim, key, settings)
    else
      {:ok, %{claim | session: %{claim.session | coop_session_id: nil}}}
    end
  end

  defp fence_cancellation_session_create(claim, key, settings) do
    response =
      mutation_call(settings, :create_session, key, fn ->
        fence_remote_session(settings, claim, key)
      end)

    case response do
      {:ok, operation} when is_map(operation) ->
        cancellation_session_from_operation(claim, operation, key, settings)

      {:error, {:coop_error, 409, "idempotency_conflict", _detail} = reason} ->
        {:error, {:work_cancellation_unresolved, {:fence_idempotency_conflict, reason}}}

      unresolved ->
        {:error, {:work_cancellation_unresolved, {:session_create_fence, unresolved}}}
    end
  end

  defp cancellation_session_from_operation(claim, operation, key, settings) do
    case operation_resource(
           operation,
           "session",
           "CreateRemoteSession",
           key,
           settings,
           settings.max_polls
         ) do
      {:ok, session_id} ->
        fetch_and_bind_cancellation_session(claim, session_id, settings)

      {:confirmed_failed, _reason} ->
        {:ok, %{claim | session: %{claim.session | coop_session_id: nil}}}

      {:uncertain, reason} ->
        {:error, {:work_cancellation_unresolved, reason}}

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_and_bind_cancellation_session(claim, session_id, settings) do
    case api_call(settings, fn -> settings.api.get_session(settings.client, session_id) end) do
      {:ok, remote_session} -> bind_cancellation_session(claim, remote_session)
      {:error, _reason} = error -> error
    end
  end

  defp bind_cancellation_session(claim, %{"id" => session_id} = remote_session)
       when is_binary(session_id) do
    with :ok <-
           exact_remote_session_state(
             claim.session,
             remote_session,
             ~w(open exhausted closed discarded)
           ),
         {:ok, session} <-
           Custody.bind_session(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.session.generation,
             claim.session.create_generation,
             session_id
           ) do
      {:ok, %{claim | session: session}}
    end
  end

  defp bind_cancellation_session(_claim, _remote_session),
    do: {:error, {:coop_protocol_error, :session_resource}}

  defp reconcile_cancellation_turn(%{session: %{coop_session_id: nil}} = claim, _settings),
    do: {:ok, claim, :not_created}

  defp reconcile_cancellation_turn(
         %{turn: %{coop_turn_id: turn_id}} = claim,
         settings
       )
       when is_binary(turn_id) do
    with {:ok, remote_turn} <- fetch_turn(claim, turn_id, settings) do
      {:ok, claim, remote_turn}
    end
  end

  defp reconcile_cancellation_turn(%{turn: %{submission: nil}} = claim, _settings),
    do: {:ok, claim, :not_created}

  defp reconcile_cancellation_turn(claim, settings) do
    key = turn_key(claim.turn)

    if frozen_remote_operation?(claim.turn, "submit_turn", key) do
      fence_cancellation_turn_submit(claim, key, settings)
    else
      {:ok, claim, :not_created}
    end
  end

  defp fence_cancellation_turn_submit(claim, key, settings) do
    revision = claim.turn.remote_operation_revision

    response =
      with {:ok, artifacts} <- input_artifacts(claim) do
        mutation_call(settings, :submit_turn, key, revision, fn ->
          fence_frozen_turn(settings, claim, key, revision, artifacts)
        end)
      end

    case response do
      {:ok, operation} when is_map(operation) ->
        cancellation_turn_from_operation(claim, operation, key, settings)

      {:error, {:coop_error, 409, "idempotency_conflict", _detail} = reason} ->
        {:error, {:work_cancellation_unresolved, {:fence_idempotency_conflict, reason}}}

      unresolved ->
        {:error, {:work_cancellation_unresolved, {:turn_submit_fence, unresolved}}}
    end
  end

  defp cancellation_turn_from_operation(claim, operation, key, settings) do
    case operation_resource(
           operation,
           "turn",
           "SubmitTurn",
           key,
           settings,
           settings.max_polls
         ) do
      {:ok, turn_id} ->
        fetch_and_bind_turn(claim, turn_id, settings)

      {:confirmed_failed, _reason} ->
        {:ok, claim, :not_created}

      {:uncertain, reason} ->
        {:error, {:work_cancellation_unresolved, reason}}

      {:error, _reason} = error ->
        error
    end
  end

  defp frozen_remote_operation?(turn, kind, key),
    do: turn.remote_operation_kind == kind and turn.remote_operation_key == key

  defp input_artifacts(claim) do
    claim.turn.submission
    |> Map.get("input_artifact_refs", [])
    |> Artifacts.coop_inputs()
  end

  defp cancel_remote_turn(claim, key, remote_turn, settings) do
    case operation_by_key(settings, key) do
      :not_found -> mutate_cancellation(claim, key, remote_turn, settings)
      {:ok, operation} -> cancellation_from_operation(claim, operation, key, settings)
      {:error, _reason} = error -> error
    end
  end

  defp mutate_cancellation(claim, key, _remote_turn, settings) do
    with {:ok, remote_session} <-
           api_call(settings, fn ->
             settings.api.get_session(settings.client, claim.session.coop_session_id)
           end),
         :ok <- exact_remote_session(claim.session, remote_session),
         {:ok, observed_revision} <- revision(remote_session),
         {:ok, turn} <-
           Custody.freeze_cancellation_revision(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             :cancel_turn,
             observed_revision
           ) do
      revision = turn.cancel_expected_revision

      response =
        mutation_call(settings, :cancel_turn, key, fn ->
          settings.api.cancel_turn(
            settings.client,
            claim.session.coop_session_id,
            claim.turn.coop_turn_id,
            key,
            revision
          )
        end)

      handle_cancellation_response(response, claim, key, settings)
    end
  end

  defp handle_cancellation_response(
         {:ok, %{"turn" => cancelled}},
         claim,
         key,
         settings
       )
       when is_map(cancelled) do
    case settle_remote_cancellation(claim, key, cancelled, settings) do
      {:ok, _execution} = success -> success
      {:error, reason} -> reconcile_cancellation_response(claim, key, reason, settings)
    end
  end

  defp handle_cancellation_response(
         {:ok, %{"operation" => operation}},
         claim,
         key,
         settings
       )
       when is_map(operation),
       do: cancellation_from_operation(claim, operation, key, settings)

  defp handle_cancellation_response({:ok, _response}, claim, key, settings),
    do: reconcile_cancellation_response(claim, key, :cancel_turn_response, settings)

  defp handle_cancellation_response(
         {:error, {:coop_error, 409, "revision_conflict", _detail} = reason},
         claim,
         _key,
         _settings
       ),
       do: spend_cancellation_generation(claim, reason)

  defp handle_cancellation_response(
         {:error, {:coop_error, 409, "operation_uncertain", _detail} = reason},
         claim,
         key,
         settings
       ),
       do: reconcile_uncertain_cancellation(claim, key, reason, settings)

  defp handle_cancellation_response({:error, _reason} = error, claim, key, settings),
    do: reconcile_cancellation_transport(error, claim, key, settings)

  defp reconcile_cancellation_response(claim, key, reason, settings) do
    reconcile_after_transport(ambiguous_mutation(:cancel_turn, reason), key, settings, fn
      operation -> cancellation_from_operation(claim, operation, key, settings)
    end)
  end

  defp reconcile_cancellation_transport(error, claim, key, settings) do
    case fetch_bound_turn(claim, settings) do
      {:ok, %{"state" => state} = current} when state in @terminal_turn_states ->
        settle_remote_cancellation(claim, key, current, settings)

      _not_proven ->
        reconcile_after_transport(error, key, settings, fn operation ->
          cancellation_from_operation(claim, operation, key, settings)
        end)
    end
  end

  defp cancellation_from_operation(claim, operation, key, settings) do
    case operation_resource(
           operation,
           "turn",
           "CancelTurn",
           key,
           settings,
           settings.max_polls
         ) do
      {:ok, turn_id} ->
        with {:ok, remote_turn} <- fetch_turn(claim, turn_id, settings) do
          settle_remote_cancellation(claim, key, remote_turn, settings)
        end

      {:confirmed_failed, reason} ->
        spend_cancellation_generation(claim, reason)

      {:uncertain, reason} ->
        reconcile_uncertain_cancellation(claim, key, reason, settings)

      {:error, _reason} = error ->
        error
    end
  end

  defp reconcile_uncertain_cancellation(claim, key, reason, settings) do
    with {:ok, remote_turn} <- fetch_bound_turn(claim, settings) do
      if terminal_turn?(remote_turn),
        do: settle_remote_cancellation(claim, key, remote_turn, settings),
        else: {:error, {:work_cancellation_unresolved, reason}}
    end
  end

  defp settle_remote_cancellation(claim, key, %{"state" => state} = remote_turn, settings)
       when state in @terminal_turn_states do
    with :ok <-
           exact_remote_turn(
             remote_turn,
             claim.session.coop_session_id,
             claim.turn.coop_turn_id,
             StateBinding.binding_digest(claim.turn)
           ),
         {:ok, remote_session} <- fetch_cancellation_session(claim, settings) do
      finish_cancellation_session(
        claim,
        {:terminal, key, remote_turn},
        remote_session,
        settings
      )
    end
  end

  defp settle_remote_cancellation(_claim, _key, _remote_turn, _settings),
    do: {:error, {:coop_protocol_error, :cancel_turn_not_terminal}}

  defp settle_absent_cancellation(%{session: %{coop_session_id: nil}} = claim, _settings) do
    with {:ok, receipt} <- absent_receipt(claim, nil, nil, nil),
         {:ok, settled} <-
           Custody.settle_cancellation(
             claim.episode.id,
             claim.episode.key,
             claim.turn.turn_ref,
             claim.lease_ref,
             receipt
           ) do
      {:ok,
       %{
         episode: settled.episode,
         remote_session_id: claim.session.coop_session_id,
         remote_turn_id: nil,
         status: cancellation_status(claim.turn.cancellation_intent),
         turn: settled.turn
       }}
    end
  end

  defp settle_absent_cancellation(claim, settings) do
    with {:ok, remote_session} <- fetch_cancellation_session(claim, settings) do
      finish_cancellation_session(claim, :absent, remote_session, settings)
    end
  end

  defp fetch_cancellation_session(claim, settings) do
    with {:ok, remote_session} <-
           api_call(settings, fn ->
             settings.api.get_session(settings.client, claim.session.coop_session_id)
           end),
         :ok <-
           exact_remote_session_state(
             claim.session,
             remote_session,
             ~w(open exhausted closed discarded)
           ) do
      {:ok, remote_session}
    end
  end

  defp reusable_transfer_session?(%{"action" => "transfer"}, %{"state" => state}),
    do: state == "open"

  defp reusable_transfer_session?(_intent, _session), do: false

  defp finish_cancellation_session(claim, proof, remote_session, settings) do
    cond do
      reusable_transfer_session?(claim.turn.cancellation_intent, remote_session) ->
        settle_cancellation_proof(claim, proof, remote_session, nil)

      remote_session["state"] in ~w(closed discarded) ->
        settle_cancellation_proof(claim, proof, remote_session, nil)

      true ->
        close_cancellation_session(claim, proof, remote_session, settings)
    end
  end

  defp close_cancellation_session(
         claim,
         proof,
         %{"state" => state} = remote_session,
         _settings
       )
       when state in ~w(closed discarded),
       do: settle_cancellation_proof(claim, proof, remote_session, nil)

  defp close_cancellation_session(claim, proof, remote_session, settings) do
    key = cancellation_close_key(claim.turn)

    case operation_by_key(settings, key) do
      :not_found ->
        mutate_cancellation_close(claim, proof, remote_session, key, settings)

      {:ok, operation} ->
        cancellation_close_from_operation(claim, proof, operation, key, settings)

      {:error, _reason} = error ->
        error
    end
  end

  defp mutate_cancellation_close(claim, proof, remote_session, key, settings) do
    with {:ok, observed_revision} <- revision(remote_session),
         {:ok, turn} <-
           Custody.freeze_cancellation_revision(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             :close_session,
             observed_revision
           ) do
      revision = turn.close_expected_revision

      response =
        mutation_call(settings, :close_session, key, fn ->
          settings.api.close_session(
            settings.client,
            claim.session.coop_session_id,
            key,
            revision
          )
        end)

      handle_cancellation_close_response(response, claim, proof, key, settings)
    end
  end

  defp handle_cancellation_close_response(
         {:ok, %{"session" => remote_session}},
         claim,
         proof,
         key,
         settings
       )
       when is_map(remote_session) do
    result =
      with :ok <-
             exact_remote_session_state(claim.session, remote_session, ~w(closed discarded)) do
        settle_cancellation_proof(claim, proof, remote_session, key)
      end

    case result do
      {:ok, _execution} = success ->
        success

      {:error, reason} ->
        reconcile_cancellation_close_response(claim, proof, key, reason, settings)
    end
  end

  defp handle_cancellation_close_response(
         {:ok, %{"operation" => operation}},
         claim,
         proof,
         key,
         settings
       )
       when is_map(operation),
       do: cancellation_close_from_operation(claim, proof, operation, key, settings)

  defp handle_cancellation_close_response({:ok, _response}, claim, proof, key, settings),
    do:
      reconcile_cancellation_close_response(
        claim,
        proof,
        key,
        :close_session_response,
        settings
      )

  defp handle_cancellation_close_response(
         {:error, {:coop_error, 409, "revision_conflict", _detail} = reason},
         claim,
         _proof,
         _key,
         _settings
       ),
       do: spend_cancellation_generation(claim, reason)

  defp handle_cancellation_close_response(
         {:error, {:coop_error, 409, "operation_uncertain", _detail} = reason},
         claim,
         proof,
         key,
         settings
       ),
       do: reconcile_uncertain_close(claim, proof, key, reason, settings)

  defp handle_cancellation_close_response(
         {:error, _reason} = error,
         claim,
         proof,
         key,
         settings
       ) do
    reconcile_after_transport(error, key, settings, fn operation ->
      cancellation_close_from_operation(claim, proof, operation, key, settings)
    end)
  end

  defp reconcile_cancellation_close_response(claim, proof, key, reason, settings) do
    reconcile_after_transport(ambiguous_mutation(:close_session, reason), key, settings, fn
      operation -> cancellation_close_from_operation(claim, proof, operation, key, settings)
    end)
  end

  defp cancellation_close_from_operation(claim, proof, operation, key, settings) do
    case operation_resource(
           operation,
           "session",
           "CloseSession",
           key,
           settings,
           settings.max_polls
         ) do
      {:ok, session_id} when session_id == claim.session.coop_session_id ->
        with {:ok, remote_session} <- fetch_cancellation_session(claim, settings) do
          settle_closed_cancellation_session(
            remote_session,
            claim,
            proof,
            key,
            :session_not_closed
          )
        end

      {:ok, _session_id} ->
        {:error, {:coop_protocol_error, :session_identity}}

      {:confirmed_failed, reason} ->
        spend_cancellation_generation(claim, reason)

      {:uncertain, reason} ->
        reconcile_uncertain_close(claim, proof, key, reason, settings)

      {:error, _reason} = error ->
        error
    end
  end

  defp reconcile_uncertain_close(claim, proof, key, reason, settings) do
    with {:ok, remote_session} <- fetch_cancellation_session(claim, settings) do
      settle_closed_cancellation_session(remote_session, claim, proof, key, reason)
    end
  end

  defp settle_closed_cancellation_session(remote_session, claim, proof, key, unresolved) do
    if remote_session["state"] in ~w(closed discarded),
      do: settle_cancellation_proof(claim, proof, remote_session, key),
      else: {:error, {:work_cancellation_unresolved, unresolved}}
  end

  defp settle_cancellation_proof(claim, proof, remote_session, close_operation_ref) do
    with {:ok, receipt} <- cancellation_receipt(claim, proof, remote_session, close_operation_ref),
         {:ok, settled} <-
           Custody.settle_cancellation(
             claim.episode.id,
             claim.episode.key,
             claim.turn.turn_ref,
             claim.lease_ref,
             receipt
           ) do
      {:ok,
       %{
         episode: settled.episode,
         remote_session_id: remote_session["id"],
         remote_turn_id: remote_turn_id(proof),
         status: cancellation_status(claim.turn.cancellation_intent),
         turn: settled.turn
       }}
    end
  end

  defp cancellation_receipt(claim, :absent, remote_session, close_operation_ref) do
    absent_receipt(
      claim,
      remote_session["id"],
      remote_session["state"],
      close_operation_ref
    )
  end

  defp cancellation_receipt(
         claim,
         {:terminal, cancel_operation_ref, remote_turn},
         remote_session,
         close_operation_ref
       ) do
    Cancellation.terminal_receipt(
      claim.session.coop_session_id,
      claim.turn.coop_turn_id,
      remote_turn["state"],
      cancel_operation_ref,
      remote_session["state"],
      close_operation_ref
    )
  end

  defp remote_turn_id(:absent), do: nil
  defp remote_turn_id({:terminal, _operation_ref, remote_turn}), do: remote_turn["id"]

  defp cancellation_status(%{"action" => "cancel"}), do: :cancelled
  defp cancellation_status(%{"action" => "transfer"}), do: :transferred
  defp cancellation_status(%{"action" => "block"}), do: :blocked

  defp absent_receipt(claim, remote_session_id, session_state, close_operation_ref) do
    submit_operation_ref = if claim.turn.submission == nil, do: nil, else: turn_key(claim.turn)

    Cancellation.absent_receipt(
      create_key(claim.session),
      submit_operation_ref,
      remote_session_id,
      session_state,
      close_operation_ref
    )
  end

  defp spend_cancellation_generation(claim, reason) do
    with {:ok, _turn} <-
           Custody.advance_cancellation(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             claim.turn.cancel_generation
           ) do
      {:error, {:work_generation_spent, :cancellation, reason}}
    end
  end

  defp operation_by_key(settings, key) do
    api_call(settings, fn -> settings.api.operation_by_key(settings.client, key) end)
  end

  defp create_remote_session(settings, claim, key, task) do
    settings.api.create_session(settings.client, key, claim.session.policy, task)
  end

  defp fence_remote_session(settings, claim, key) do
    settings.api.fence_create_session(
      settings.client,
      key,
      claim.session.policy,
      claim.session.external_ref
    )
  end

  defp submit_frozen_turn(settings, claim, key, revision, artifacts) do
    settings.api.submit_frozen_turn(
      settings.client,
      claim.session.coop_session_id,
      key,
      revision,
      claim.turn.submission,
      state_binding_document(claim),
      artifacts
    )
  end

  defp fence_frozen_turn(settings, claim, key, revision, artifacts) do
    settings.api.fence_frozen_turn(
      settings.client,
      claim.session.coop_session_id,
      key,
      revision,
      claim.turn.submission,
      state_binding_document(claim),
      artifacts
    )
  end

  defp state_binding_document(%{state_binding: binding}), do: StateBinding.document(binding)
  defp state_binding_document(_claim), do: nil

  defp validate_frozen_candidate(settings, claim, key, verdict) do
    if function_exported?(settings.api, :validate_frozen_candidate, 7) do
      settings.api.validate_frozen_candidate(
        settings.client,
        claim.session.coop_session_id,
        claim.turn.coop_turn_id,
        key,
        claim.turn.candidate_attempt,
        claim.turn.candidate_sha256,
        verdict
      )
    else
      settings.api.validate_candidate(
        settings.client,
        claim.session.coop_session_id,
        claim.turn.coop_turn_id,
        key,
        claim.turn.candidate_sha256,
        verdict
      )
    end
  end

  defp fetch_bound_turn(claim, settings),
    do: fetch_turn(claim, claim.turn.coop_turn_id, settings)

  defp fetch_turn(claim, turn_id, settings) do
    with {:ok, remote_turn} <-
           api_call(settings, fn ->
             settings.api.get_turn(settings.client, claim.session.coop_session_id, turn_id)
           end),
         :ok <-
           exact_remote_turn(
             remote_turn,
             claim.session.coop_session_id,
             turn_id,
             StateBinding.binding_digest(claim.turn)
           ) do
      {:ok, remote_turn}
    end
  end

  defp operation_resource(
         %{"method" => method, "state" => "succeeded"} = operation,
         type,
         method,
         _key,
         _settings,
         _left
       ) do
    if operation["resource_type"] == type and reference?(operation["resource_id"]),
      do: {:ok, operation["resource_id"]},
      else: {:error, {:coop_protocol_error, :operation_resource}}
  end

  defp operation_resource(
         %{"method" => method, "state" => "failed"} = operation,
         _type,
         method,
         _key,
         _settings,
         _left
       ) do
    {:confirmed_failed,
     {:coop_operation_failed, operation["error_code"] || "failed",
      operation["error_detail"] || "Coop operation failed"}}
  end

  defp operation_resource(
         %{"method" => method, "state" => "uncertain"} = operation,
         _type,
         method,
         _key,
         _settings,
         _left
       ) do
    {:uncertain,
     {:coop_operation_uncertain, operation["error_code"] || "uncertain",
      operation["error_detail"] || "Coop operation outcome is uncertain"}}
  end

  defp operation_resource(
         %{"method" => method, "state" => state},
         type,
         method,
         key,
         settings,
         left
       )
       when state in @operation_waiting_states and left > 0 do
    with :ok <- pause(settings) do
      case operation_by_key(settings, key) do
        {:ok, operation} ->
          operation_resource(operation, type, method, key, settings, left - 1)

        :not_found ->
          {:error, {:coop_protocol_error, :operation_disappeared}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp operation_resource(
         %{"method" => method, "state" => state},
         _type,
         method,
         _key,
         _settings,
         0
       )
       when state in @operation_waiting_states,
       do: {:error, {:work_poll_window_elapsed, :operation}}

  defp operation_resource(
         %{"method" => _actual},
         _type,
         _expected_method,
         _key,
         _settings,
         _left
       ),
       do: {:error, {:coop_protocol_error, :operation_method}}

  defp operation_resource(_operation, _type, _method, _key, _settings, _left),
    do: {:error, {:coop_protocol_error, :operation_state}}

  defp reconcile_after_transport(original_error, key, settings, continuation) do
    case operation_by_key(settings, key) do
      {:ok, operation} -> continuation.(operation)
      :not_found -> original_error
      {:error, _reason} -> original_error
    end
  end

  defp ambiguous_mutation(phase, reason),
    do: {:error, {:coop_mutation_response_unresolved, phase, reason}}

  defp validation_context(claim, artifacts, settings) do
    case settings.validation_context.(claim) do
      %{} = context -> complete_validation_context(context, claim, artifacts, settings)
      {:ok, %{} = context} -> complete_validation_context(context, claim, artifacts, settings)
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_work_executor, :validation_context}}
    end
  end

  defp complete_validation_context(context, claim, artifacts, settings) do
    with {:ok, workspace} <- workspace_validation_context(claim, settings) do
      {:ok,
       context
       |> Map.put("artifact_metadata", Enum.map(artifacts, &Map.take(&1, ~w(id name))))
       |> Map.put("artifact_refs", Outputs.refs(artifacts))
       |> Map.put("execution_mode", Atom.to_string(claim.episode.execution_mode))
       |> Map.put_new(
         "artifact_delivery_supported",
         artifact_delivery_supported?(claim.episode)
       )
       |> Map.put_new("open_required_goals", Records.open_required_goals(claim.episode.id))
       |> Map.put("slack_mentions", Mentions.authority(claim.episode))
       |> Map.put("workspace", workspace)}
    end
  end

  defp default_validation_context(claim) do
    context = claim.turn.submission["context"]

    %{
      "artifact_delivery_supported" => artifact_delivery_supported?(claim.episode),
      "artifact_metadata" => [],
      "artifact_refs" => [],
      "execution_mode" => Atom.to_string(claim.episode.execution_mode),
      "open_required_goals" => Records.open_required_goals(claim.episode.id),
      "records" => validation_records(claim.episode.id, claim.turn.id),
      "slack_mentions" => Mentions.authority(claim.episode),
      "visible_reply_required" =>
        claim.episode.execution_mode == :live and visible_reply_required?(context),
      "workspace" => nil
    }
  end

  defp artifact_delivery_supported?(episode) do
    episode.execution_mode == :live and
      episode.destination_transport in ["slack", "control_plane"]
  end

  defp validation_records(episode_id, turn_id) do
    Map.merge(
      Records.validation_records(episode_id),
      PlatformActionCustody.validation_records(episode_id, turn_id)
    )
  end

  defp workspace_validation_context(claim, settings) do
    case workspace_requirements(claim) do
      [] ->
        {:ok, nil}

      goals ->
        with true <- function_exported?(settings.api, :get_changes, 2),
             {:ok, changes} <-
               api_call(settings, fn ->
                 settings.api.get_changes(settings.client, claim.session.coop_session_id)
               end),
             {:ok, prepared} <- prepare_workspace_changes(changes, goals) do
          {:ok, prepared}
        else
          false -> {:error, {:invalid_work_executor, :workspace_changes_api}}
          {:error, _reason} = error -> error
        end
    end
  end

  defp workspace_requirements(%{
         session: %{
           repository_ref: repository,
           workspace_task: %{"offer_ref" => offer_ref}
         }
       })
       when is_binary(repository) and is_binary(offer_ref) do
    [%{"id" => offer_ref, "writable_repository" => repository}]
  end

  defp workspace_requirements(claim), do: Records.repository_write_goals(claim.episode.id)

  defp prepare_workspace_changes(changes, goals) when is_map(changes) do
    with {:ok, base_commit} <- workspace_identity(changes["base_commit"]),
         {:ok, fork_head} <- workspace_identity(changes["fork_head"]),
         {:ok, fork_tree} <- workspace_identity(changes["fork_tree"]),
         {:ok, pull_request_tree} <- optional_workspace_identity(changes["pull_request_tree"]),
         {:ok, committed_count} <- workspace_change_count(changes["committed"]),
         {:ok, staged_count} <- workspace_change_count(changes["staged"]),
         {:ok, unstaged_count} <- workspace_change_count(changes["unstaged"]),
         {:ok, untracked_count} <- workspace_change_count(changes["untracked"]),
         {:ok, conflict_count} <- workspace_change_count(changes["conflicts"]),
         {:ok, repository} <- repository_write_goal_repository(goals) do
      {:ok,
       %{
         "base_commit" => base_commit,
         "committed_count" => committed_count,
         "conflict_count" => conflict_count,
         "fork_head" => fork_head,
         "fork_tree" => fork_tree,
         "goal_ids" => Enum.map(goals, & &1["id"]),
         "pull_request_tree" => pull_request_tree,
         "repository" => repository,
         "staged_count" => staged_count,
         "unstaged_count" => unstaged_count,
         "untracked_count" => untracked_count
       }}
    end
  end

  defp prepare_workspace_changes(_changes, _goals),
    do: {:error, {:coop_protocol_error, :workspace_changes}}

  defp workspace_identity(value) when is_binary(value) and byte_size(value) in 1..256 do
    if :binary.match(value, <<0>>) == :nomatch,
      do: {:ok, value},
      else: {:error, {:coop_protocol_error, :workspace_changes}}
  end

  defp workspace_identity(_value), do: {:error, {:coop_protocol_error, :workspace_changes}}

  defp optional_workspace_identity(nil), do: {:ok, nil}
  defp optional_workspace_identity(value), do: workspace_identity(value)

  defp workspace_change_count(changes) when is_list(changes) and length(changes) <= 100_000,
    do: {:ok, length(changes)}

  defp workspace_change_count(_changes),
    do: {:error, {:coop_protocol_error, :workspace_changes}}

  defp repository_write_goal_repository([first | rest]) do
    repository = first["writable_repository"]

    if is_binary(repository) and byte_size(repository) in 1..256 and
         Enum.all?(rest, &(&1["writable_repository"] == repository)) do
      {:ok, repository}
    else
      {:error, {:invalid_work_state, :repository_write_goals}}
    end
  end

  defp output_artifact_metadata(remote_turn) do
    remote_turn
    |> Map.get("output_artifacts", [])
    |> Outputs.prepare_metadata()
  end

  defp retain_selected_artifacts(claim, metadata, settings) do
    with {:ok, refs} <- accepted_artifact_refs(claim.turn.validation_intent),
         {:ok, selected} <- select_artifact_metadata(metadata, refs),
         {:ok, fetched} <- fetch_output_artifacts(claim, selected, settings) do
      Outputs.put_many(claim.turn.id, fetched)
    end
  end

  defp accepted_artifact_refs(intent) do
    case ValidationIntent.result(intent) do
      {:ok, %{delivery: :none}} ->
        {:ok, []}

      {:ok, %{delivery_document: %{"outcome" => %{"artifact_refs" => refs}}}}
      when is_list(refs) ->
        {:ok, refs}

      {:ok, %{delivery_document: %{"message" => _message}}} ->
        {:ok, []}

      _invalid ->
        {:error, {:coop_protocol_error, :accepted_artifact_refs}}
    end
  end

  defp select_artifact_metadata(metadata, refs) do
    by_ref = Map.new(metadata, &{&1["id"], &1})

    if Enum.all?(refs, &Map.has_key?(by_ref, &1)),
      do: {:ok, Enum.map(refs, &Map.fetch!(by_ref, &1))},
      else: {:error, {:coop_protocol_error, :accepted_artifact_metadata}}
  end

  defp fetch_output_artifacts(claim, metadata, settings) do
    Enum.reduce_while(metadata, {:ok, []}, fn expected, {:ok, fetched} ->
      result =
        api_call(settings, fn ->
          settings.api.get_output_artifact(
            settings.client,
            claim.session.coop_session_id,
            claim.turn.coop_turn_id,
            expected["id"]
          )
        end)

      case verify_output_artifact(expected, result) do
        {:ok, artifact} -> {:cont, {:ok, [artifact | fetched]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, fetched} -> {:ok, Enum.reverse(fetched)}
      {:error, _reason} = error -> error
    end
  end

  defp verify_output_artifact(expected, {:ok, %{"data" => data} = fetched})
       when is_binary(data) do
    actual = Map.take(fetched, ~w(bytes id media_type sha256))
    expected_identity = Map.take(expected, ~w(bytes id media_type sha256))

    if actual == expected_identity,
      do: {:ok, Map.put(expected, "data", data)},
      else: {:error, {:coop_protocol_error, :output_artifact_identity}}
  end

  defp verify_output_artifact(_expected, {:error, _reason} = error), do: error

  defp verify_output_artifact(_expected, _result),
    do: {:error, {:coop_protocol_error, :output_artifact}}

  defp visible_reply_required?(%{"mode" => "full", "inputs" => %{"items" => items}}),
    do: Enum.any?(items, &human_input?/1)

  defp visible_reply_required?(%{
         "mode" => "continuation",
         "continuity" => %{"first_input" => first},
         "current_inputs" => %{"items" => items}
       }) do
    human_input?(first) or Enum.any?(items, &human_input?/1)
  end

  defp visible_reply_required?(_context), do: false

  defp human_input?(%{"actor_ref" => actor_ref}) when is_binary(actor_ref),
    do: String.contains?(actor_ref, ":user:")

  defp human_input?(_input), do: false

  defp candidate_fields(%{
         "attempt" => attempt,
         "message" => message,
         "sha256" => sha256
       })
       when is_integer(attempt) and attempt > 0 and is_binary(message) and is_binary(sha256) do
    if digest(message) == sha256,
      do: {:ok, message, sha256, attempt},
      else: {:error, {:coop_protocol_error, :candidate_digest}}
  end

  defp candidate_fields(_candidate), do: {:error, {:coop_protocol_error, :candidate}}

  defp completed_fields(%{
         "assistant_message" => message,
         "validation_attempt" => attempt,
         "validation_candidate_sha256" => sha256,
         "validation_receipt" => receipt
       })
       when is_binary(message) and is_integer(attempt) and attempt > 0 and is_binary(sha256) and
              is_binary(receipt) do
    if digest(message) == sha256 and reference?(receipt),
      do: {:ok, message, sha256, attempt, receipt},
      else: {:error, {:coop_protocol_error, :validation_receipt}}
  end

  defp completed_fields(%{"validation_attempt" => attempt})
       when not is_integer(attempt) or attempt < 1,
       do: {:error, {:coop_protocol_error, :validation_attempt}}

  defp completed_fields(%{"validation_attempt" => _attempt}),
    do: {:error, {:coop_protocol_error, :validation_receipt}}

  defp completed_fields(_turn), do: {:error, {:coop_protocol_error, :validation_attempt}}

  defp validation_verdict(%{"verdict" => "accept"}), do: :accept

  defp validation_verdict(%{"verdict" => "reject", "violations" => violations}),
    do: {:reject, violations}

  defp create_key(session),
    do: "responder:work:create:#{session.id}:g#{session.create_generation}"

  defp turn_key(turn),
    do: "responder:work:turn:#{turn.id}:g#{turn.submit_generation}:#{turn.submission_fingerprint}"

  defp validation_key(turn, verdict) do
    verdict_name = if verdict == :accept, do: "accept", else: "reject"

    "responder:work:validate:#{turn.id}:a#{turn.candidate_attempt}:g#{turn.validation_generation}:#{turn.candidate_sha256}:#{verdict_name}"
  end

  defp checkpoint_key(turn),
    do: "responder:work:checkpoint:#{turn.id}:a#{turn.candidate_attempt}:#{turn.candidate_sha256}"

  defp cancellation_close_key(turn),
    do: "responder:work:cancel-close:#{turn.id}:g#{turn.cancel_generation}"

  defp revision(%{"revision" => revision}) when is_integer(revision) and revision > 0,
    do: {:ok, revision}

  defp revision(_resource), do: {:error, {:coop_protocol_error, :resource_revision}}

  defp terminal_turn?(%{"state" => state}), do: state in @terminal_turn_states
  defp terminal_turn?(_turn), do: false

  defp exact_remote_session(expected, %{"state" => "open"} = remote_session),
    do: exact_remote_session_state(expected, remote_session, ["open"])

  defp exact_remote_session(_expected, _remote_session),
    do: {:error, {:coop_protocol_error, :session_resource}}

  defp exact_remote_session_state(
         expected,
         %{
           "external_ref" => external_ref,
           "id" => id,
           "policy" => policy,
           "policy_digest" => policy_digest,
           "state" => state
         } = remote_session,
         allowed_states
       ) do
    remote_authority = {policy, policy_digest, external_ref}
    expected_authority = {expected.policy, expected.policy_digest, expected.external_ref}

    with :ok <- exact_remote_session_identity(expected, id),
         :ok <- exact_remote_session_allowed_state(state, allowed_states),
         true <- remote_authority == expected_authority,
         true <- session_authority_digest_matches?(expected, remote_session),
         true <- is_nil(Map.get(remote_session, "responder_binding_digest")) do
      :ok
    else
      false -> {:error, {:coop_protocol_error, :session_authority}}
      {:error, _reason} = error -> error
    end
  end

  defp exact_remote_session_state(_expected, _remote_session, _allowed_states),
    do: {:error, {:coop_protocol_error, :session_resource}}

  defp exact_remote_session_identity(expected, id) do
    if expected.coop_session_id in [nil, id] and reference?(id),
      do: :ok,
      else: {:error, {:coop_protocol_error, :session_identity}}
  end

  defp exact_remote_session_allowed_state(state, allowed_states) do
    if state in allowed_states,
      do: :ok,
      else: {:error, {:coop_protocol_error, :session_state}}
  end

  defp session_authority_digest_matches?(%{authority_digest: nil}, _remote_session), do: true

  defp session_authority_digest_matches?(expected, remote_session),
    do: remote_session["authority_digest"] == expected.authority_digest

  defp exact_remote_turn(
         %{"id" => id, "session_id" => session_id} = remote_turn,
         expected_session_id,
         expected_turn_id,
         expected_binding_digest
       )
       when is_binary(id) and is_binary(session_id) do
    cond do
      session_id != expected_session_id ->
        {:error, {:coop_protocol_error, :turn_session_identity}}

      expected_turn_id != nil and id != expected_turn_id ->
        {:error, {:coop_protocol_error, :turn_identity}}

      not reference?(id) ->
        {:error, {:coop_protocol_error, :turn_identity}}

      Map.get(remote_turn, "responder_binding_digest") != expected_binding_digest ->
        {:error, {:coop_protocol_error, :turn_authority}}

      true ->
        :ok
    end
  end

  defp exact_remote_turn(
         _remote_turn,
         _expected_session_id,
         _expected_turn_id,
         _expected_binding_digest
       ),
       do: {:error, {:coop_protocol_error, :turn_resource}}

  defp api_call(settings, function) do
    with :ok <- maybe_renew(settings) do
      function.()
    end
  end

  defp mutation_call(settings, kind, key, function),
    do: mutation_call(settings, kind, key, nil, function)

  defp mutation_call(settings, kind, key, revision, function) do
    result =
      Custody.with_mutation_fence(
        settings.claim.episode.id,
        settings.claim.turn.turn_ref,
        settings.claim.lease_ref,
        %{
          kind: kind,
          lease_seconds: settings.lease_seconds,
          maximum_block_ms: settings.max_block_ms,
          operation_key: key,
          operation_revision: revision
        },
        function
      )

    Process.put(settings.heartbeat_key, settings.monotonic_ms.())
    result
  end

  defp pause(settings) do
    settings.sleep.(settings.poll_interval_ms)
    maybe_renew(settings)
  end

  defp maybe_renew(settings) do
    now = settings.monotonic_ms.()
    last = Process.get(settings.heartbeat_key, now)

    if now - last >= settings.heartbeat_interval_ms do
      case Custody.renew(
             settings.claim.episode.id,
             settings.claim.turn.turn_ref,
             settings.claim.lease_ref,
             settings.lease_seconds
           ) do
        {:ok, _turn} ->
          Process.put(settings.heartbeat_key, now)
          :ok

        {:error, _reason} = error ->
          error
      end
    else
      :ok
    end
  end

  defp settings(options) when is_list(options) do
    allowed = [
      :api,
      :client,
      :lease_seconds,
      :max_block_ms,
      :max_polls,
      :monotonic_ms,
      :now,
      :poll_interval_ms,
      :platform_tools,
      :require_project_isolation,
      :require_repository_read_only,
      :sleep,
      :state_tool_capabilities,
      :state_tools_endpoint,
      :state_tools_secret,
      :validation_context,
      :workspace_requirements
    ]

    if Keyword.keyword?(options) and Enum.all?(Keyword.keys(options), &(&1 in allowed)) do
      state_tools_endpoint = Keyword.get(options, :state_tools_endpoint)

      validate_settings(%{
        api: Keyword.get(options, :api, Responder.Coop.Client),
        client: Keyword.fetch!(options, :client),
        lease_seconds: Keyword.get(options, :lease_seconds, 300),
        max_block_ms: Keyword.get(options, :max_block_ms, 30_000),
        max_polls: Keyword.get(options, :max_polls, 600),
        monotonic_ms:
          Keyword.get(options, :monotonic_ms, fn ->
            System.monotonic_time(:millisecond)
          end),
        now: Keyword.get(options, :now, &DateTime.utc_now/0),
        poll_interval_ms: Keyword.get(options, :poll_interval_ms, 250),
        platform_tools: Keyword.get(options, :platform_tools),
        require_project_isolation: Keyword.get(options, :require_project_isolation, false),
        require_repository_read_only: Keyword.get(options, :require_repository_read_only, false),
        sleep: Keyword.get(options, :sleep, &Process.sleep/1),
        state_tool_capabilities:
          Keyword.get(
            options,
            :state_tool_capabilities,
            if(state_tools_endpoint, do: @default_state_tool_capabilities, else: nil)
          ),
        state_tools_endpoint: state_tools_endpoint,
        state_tools_secret: Keyword.get(options, :state_tools_secret),
        validation_context:
          Keyword.get(options, :validation_context, &default_validation_context/1),
        workspace_requirements: Keyword.get(options, :workspace_requirements, [])
      })
    else
      {:error, {:invalid_work_executor, :options}}
    end
  rescue
    KeyError -> {:error, {:invalid_work_executor, :options}}
  end

  defp settings(_options), do: {:error, {:invalid_work_executor, :options}}

  defp validate_settings(settings) do
    safe_window = div(settings.lease_seconds * 1_000, 3)

    validations = [
      {is_atom(settings.api), :api},
      {is_integer(settings.lease_seconds) and settings.lease_seconds > 0, :lease_seconds},
      {is_integer(settings.max_block_ms) and settings.max_block_ms > 0 and
         settings.max_block_ms < safe_window, :max_block_ms},
      {is_integer(settings.max_polls) and settings.max_polls > 0, :max_polls},
      {is_function(settings.monotonic_ms, 0), :monotonic_ms},
      {is_function(settings.now, 0), :now},
      {is_integer(settings.poll_interval_ms) and settings.poll_interval_ms >= 0 and
         settings.poll_interval_ms < safe_window, :poll_interval_ms},
      {valid_platform_tools?(settings.platform_tools), :platform_tools},
      {is_boolean(settings.require_project_isolation), :require_project_isolation},
      {is_boolean(settings.require_repository_read_only), :require_repository_read_only},
      {is_function(settings.sleep, 1), :sleep},
      {valid_state_tools_settings?(settings), :state_tools_binding},
      {valid_state_tool_capabilities?(settings), :state_tool_capabilities},
      {is_function(settings.validation_context, 1), :validation_context},
      {valid_workspace_requirements?(settings.workspace_requirements), :workspace_requirements}
    ]

    case Enum.find(validations, fn {valid?, _field} -> not valid? end) do
      nil ->
        {:ok,
         Map.put(settings, :heartbeat_interval_ms, max(div(settings.lease_seconds * 1_000, 3), 1))}

      {_false, field} ->
        {:error, {:invalid_work_executor, field}}
    end
  end

  defp valid_state_tools_settings?(%{state_tools_endpoint: nil, state_tools_secret: nil}),
    do: true

  defp valid_state_tools_settings?(%{
         state_tools_endpoint: endpoint,
         state_tools_secret: secret
       }) do
    match?(
      {:ok, _binding},
      StateBinding.derive(
        %Responder.Work.Session{id: Ecto.UUID.generate()},
        %Responder.Work.Turn{id: Ecto.UUID.generate()},
        "local:configuration-validation",
        endpoint,
        secret
      )
    )
  end

  defp valid_state_tool_capabilities?(%{
         state_tool_capabilities: nil,
         state_tools_endpoint: nil
       }),
       do: true

  defp valid_state_tool_capabilities?(%{
         state_tool_capabilities: capabilities,
         state_tools_endpoint: endpoint
       })
       when is_binary(endpoint) and is_list(capabilities) do
    capabilities == Enum.uniq(capabilities) and
      Enum.all?(capabilities, &(&1 in @state_tool_capabilities))
  end

  defp valid_state_tool_capabilities?(_settings), do: false

  defp valid_platform_tools?(nil), do: true

  defp valid_platform_tools?(tools) when is_list(tools) do
    names =
      Enum.map(tools, fn
        %{"name" => name} when is_binary(name) -> name
        name when is_binary(name) -> name
        _invalid -> nil
      end)

    Enum.all?(names, &is_binary/1) and names == Enum.uniq(names)
  end

  defp valid_platform_tools?(_tools), do: false

  defp valid_workspace_requirements?(requirements)
       when is_list(requirements) and length(requirements) <= 32 do
    names =
      Enum.map(requirements, fn
        %{"base_commit" => base_commit, "name" => name} = requirement
        when map_size(requirement) == 2 ->
          if is_binary(name) and Regex.match?(@companion_name_regex, name) and
               git_commit?(base_commit),
             do: name,
             else: nil

        _invalid ->
          nil
      end)

    Enum.all?(names, &is_binary/1) and names == Enum.uniq(names)
  end

  defp valid_workspace_requirements?(_requirements), do: false

  defp valid_claim(%{
         episode: %{id: episode_id},
         lease_ref: lease_ref,
         session: %{episode_id: episode_id},
         turn: %{episode_id: episode_id, lease_ref: lease_ref}
       })
       when is_binary(episode_id) and is_binary(lease_ref),
       do: :ok

  defp valid_claim(_claim), do: {:error, {:invalid_work_executor, :claim}}

  defp reference?(value) do
    is_binary(value) and String.valid?(value) and byte_size(value) in 1..1_024 and
      :binary.match(value, <<0>>) == :nomatch and String.trim(value) != ""
  end

  defp git_commit?(value),
    do: is_binary(value) and Regex.match?(@git_commit_regex, value)

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
