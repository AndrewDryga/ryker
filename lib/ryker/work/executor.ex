defmodule Ryker.Work.Executor do
  @moduledoc """
  Crash-safe execution of one leased episode turn through Coop.

  Every mutating request is keyed from durable Work rows. The exact prompt,
  schema, candidate, and semantic verdict are frozen before their respective
  remote mutations. Lost responses reconcile the operation and remote resource
  rather than spending another model turn.

  This module validates the options and the claim and sequences one turn.
  `Executor.Sessions` binds the remote session, `Executor.Workspace` proves the
  workspace matches the frozen session, `Executor.Turns` submits and awaits the
  turn, `Executor.Validation` freezes and delivers each candidate verdict,
  `Executor.Cancellation` settles a cancel-pending turn, and `Executor.Remote`
  is the Coop call layer they all share.
  """

  alias Ryker.State.KnowledgeSnapshot
  alias Ryker.Work.{Custody, StateBinding, SubmissionBuilder}
  alias Ryker.Work.Executor.{Cancellation, Remote, Sessions, Turns, Validation, Workspace}

  @default_state_tool_capabilities [:event_waits, :publication, :schedules]
  @state_tool_capabilities [:emisar_approvals, :event_waits, :publication, :schedules]

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
          :cancel_pending -> Cancellation.execute_cancellation(claim, settings)
          :delivery_pending -> {:error, :work_delivery_requires_gateway}
          _other -> {:error, :work_turn_not_executable}
        end
      after
        Process.delete(heartbeat_key)
      end
    end
  end

  defp execute_turn(%{turn: %{completion_receipt: proof}} = claim, settings)
       when is_map(proof) do
    result =
      with :ok <- KnowledgeSnapshot.authorize_session(claim.episode, claim.session),
           :ok <-
             KnowledgeSnapshot.authorize_submission(
               claim.episode,
               claim.session.repository_ref,
               claim.turn.submission
             ),
           {:ok, remote_turn} <- Remote.fetch_bound_turn(claim, settings),
           {:ok, ^proof} <- Turns.completion_proof(claim, remote_turn) do
        Turns.finalize_completed(claim, remote_turn, proof, settings)
      else
        {:ok, _changed_proof} -> {:error, {:coop_protocol_error, :completion_receipt_changed}}
        {:error, _reason} = error -> error
      end

    Turns.completion_result(result, proof)
  end

  defp execute_turn(claim, settings) do
    with :ok <- require_workspace_checkpoint_api(claim, settings),
         {:ok, claim} <- Sessions.ensure_session(claim, settings),
         :ok <- require_workspace_task_binding(claim, settings),
         :ok <- require_repository_read_only(claim, settings),
         :ok <- require_project_isolation(claim, settings),
         {:ok, claim} <- ensure_state_binding(claim, settings),
         {:ok, claim} <- ensure_submission(claim, settings),
         :ok <- KnowledgeSnapshot.authorize_session(claim.episode, claim.session),
         :ok <-
           KnowledgeSnapshot.authorize_submission(
             claim.episode,
             claim.session.repository_ref,
             claim.turn.submission
           ),
         {:ok, claim, remote_turn} <- Turns.ensure_turn(claim, settings) do
      Turns.await_turn(claim, remote_turn, settings, settings.max_polls)
    end
  end

  # Existing turns must reconcile their completed result even after configuration
  # changes. New writable tasks must never start on an adapter unable to save them.
  defp require_workspace_checkpoint_api(
         %{
           turn: %{coop_turn_id: nil},
           session: %{workspace_task: task, repository_ref: repository}
         },
         settings
       )
       when is_map(task) and is_binary(repository) do
    if function_exported?(settings.api, :checkpoint_workspace, 4),
      do: :ok,
      else: {:error, {:invalid_work_executor, :workspace_checkpoint_api}}
  end

  defp require_workspace_checkpoint_api(_claim, _settings), do: :ok

  defp require_workspace_task_binding(
         %{turn: %{coop_turn_id: nil}, session: %{workspace_task: task}} = claim,
         settings
       )
       when is_map(task) do
    with {:ok, remote} <-
           Remote.api_call(settings, fn ->
             settings.api.get_session(settings.client, claim.session.coop_session_id)
           end),
         %{
           "offer_ref" => offer_ref,
           "id" => id,
           "queue_id" => queue_id,
           "task_id" => task_id,
           "draft_sha256" => sha
         } <- remote["workspace_task"],
         true <- offer_ref == task["offer_ref"] and is_binary(offer_ref),
         true <- remote["repository_read_only"] == false,
         true <- Enum.all?([id, queue_id, task_id], &(is_binary(&1) and &1 != "")),
         true <- is_binary(sha) and Regex.match?(~r/\A[0-9a-f]{64}\z/, sha) do
      :ok
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, {:coop_protocol_error, :workspace_task_binding}}
    end
  end

  defp require_workspace_task_binding(_claim, _settings), do: :ok

  defp require_project_isolation(_claim, %{require_project_isolation: false}), do: :ok

  defp require_project_isolation(claim, %{require_project_isolation: true} = settings) do
    with {:ok, remote_session} <-
           Remote.api_call(settings, fn ->
             settings.api.get_session(settings.client, claim.session.coop_session_id)
           end),
         :ok <-
           Remote.exact_remote_session_state(
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
           Remote.api_call(settings, fn ->
             settings.api.get_session(settings.client, claim.session.coop_session_id)
           end),
         :ok <-
           Remote.exact_remote_session_state(
             claim.session,
             remote_session,
             ~w(open exhausted closed discarded)
           ) do
      if remote_session["repository_read_only"] == true,
        do: :ok,
        else: {:error, {:coop_protocol_error, :session_repository_write_authority}}
    end
  end

  @doc false
  def ensure_state_binding(claim, %{state_tools_endpoint: nil, state_tools_secret: nil}),
    do: {:ok, claim}

  def ensure_state_binding(claim, settings) do
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
    with {:ok, workspace} <- Workspace.session_workspace(claim, settings),
         submission_options <-
           [state_tool_capabilities: settings.state_tool_capabilities, workspace: workspace]
           |> maybe_submission_option(:platform_tools, settings.platform_tools),
         {:ok, %{submission: submission, ledger: ledger}} <-
           SubmissionBuilder.prepare(claim, submission_options),
         {:ok, turn} <-
           Custody.freeze_submission(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             submission,
             # Exactly the refs the builder required present and selected, and
             # the counts it measured while selecting them.
             selected_input_refs: Enum.uniq(claim.episode.active_input_refs),
             selection_ledger: ledger
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
        api: Keyword.get(options, :api, Ryker.Coop.Client),
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
          Keyword.get(options, :validation_context, &Validation.default_validation_context/1),
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
        %Ryker.Work.Session{id: Ecto.UUID.generate()},
        %Ryker.Work.Turn{id: Ecto.UUID.generate()},
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
          if Workspace.companion_name?(name) and Remote.git_commit?(base_commit),
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
end
