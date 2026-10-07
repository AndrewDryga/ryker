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
  alias Ryker.GitObject
  alias Ryker.Knowledge.KnowledgeSnapshot
  alias Ryker.StateTools.Capabilities
  alias Ryker.Work.{Custody, PlatformTools, StateBinding, SubmissionBuilder}
  alias Ryker.Work.Executor.{Cancellation, Remote, Sessions, Turns, Validation, Workspace}

  @doc """
  Checks executor options without running anything, so a runtime refuses a
  configuration before it starts workers with it.
  """
  @spec check_options(keyword()) :: :ok | {:error, {:invalid_work_executor, atom()}}
  def check_options(options) do
    with {:ok, _settings} <- settings(options), do: :ok
  end

  @spec run(Custody.claim(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(claim, options) do
    with {:ok, settings} <- settings(options),
         :ok <- valid_claim(claim) do
      heartbeat_key = {__MODULE__, claim.turn.id, make_ref()}
      # The turn's last heartbeat, kept by the process running the turn.
      # credo:disable-for-next-line Ryker.Checks.NoProcessDictionary
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

  # The session as the worker last described it while it was ensured serves
  # every check before the submit; the submit reads it again for the revision
  # it writes against.
  defp execute_turn(claim, settings) do
    with :ok <- require_workspace_checkpoint_api(claim, settings),
         {:ok, claim, remote_session} <- Sessions.ensure_session(claim, settings),
         :ok <- Remote.exact_remote_session_state(claim.session, remote_session),
         :ok <- require_workspace_task_binding(claim, remote_session),
         :ok <- require_repository_read_only(remote_session, settings),
         :ok <- require_project_isolation(remote_session, settings),
         {:ok, claim} <- ensure_state_binding(claim, settings),
         {:ok, claim} <- ensure_submission(claim, remote_session, settings),
         :ok <- KnowledgeSnapshot.authorize_session(claim.episode, claim.session),
         {:ok, claim} <- authorize_or_rebuild(claim, remote_session, settings),
         {:ok, claim, remote_turn} <- Turns.ensure_turn(claim, settings) do
      Turns.await_turn(claim, remote_turn, settings, settings.max_polls)
    end
  end

  # Knowledge a frozen submission carries can be withdrawn before Coop sees the
  # turn: a person edits the message a fact came from, or learning replaces it.
  # Andrew edited a Chat message on 2026-10-01 while Ryker answered it and got
  # "Model work stopped" instead of a reply. A turn Coop has not seen is built
  # again from what is current, once; withdrawn knowledge never reaches the
  # model either way.
  defp authorize_or_rebuild(claim, remote_session, settings, rebuilt? \\ false) do
    case KnowledgeSnapshot.authorize_submission(
           claim.episode,
           claim.session.repository_ref,
           claim.turn.submission
         ) do
      :ok ->
        {:ok, claim}

      {:error, :work_knowledge_context_stale}
      when not rebuilt? and is_nil(claim.turn.coop_turn_id) and
             is_nil(claim.turn.remote_operation_kind) ->
        with {:ok, turn} <-
               Custody.thaw_stale_submission(
                 claim.episode.id,
                 claim.turn.turn_ref,
                 claim.lease_ref
               ),
             {:ok, claim} <- ensure_submission(%{claim | turn: turn}, remote_session, settings) do
          authorize_or_rebuild(claim, remote_session, settings, true)
        end

      {:error, _reason} = error ->
        error
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
         %{turn: %{coop_turn_id: nil}, session: %{workspace_task: task}},
         remote
       )
       when is_map(task) do
    with %{
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
      _invalid -> {:error, {:coop_protocol_error, :workspace_task_binding}}
    end
  end

  defp require_workspace_task_binding(_claim, _remote), do: :ok

  defp require_project_isolation(_remote, %{require_project_isolation: false}), do: :ok

  defp require_project_isolation(remote, %{require_project_isolation: true}) do
    if remote["project_env"] == false and remote["project_mcp"] == false,
      do: :ok,
      else: {:error, {:coop_protocol_error, :session_project_authority}}
  end

  defp require_repository_read_only(_remote, %{require_repository_read_only: false}), do: :ok

  defp require_repository_read_only(remote, %{require_repository_read_only: true}) do
    if remote["repository_read_only"] == true,
      do: :ok,
      else: {:error, {:coop_protocol_error, :session_repository_write_authority}}
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

  defp ensure_submission(%{turn: %{submission: nil}} = claim, remote_session, settings) do
    with {:ok, workspace} <- Workspace.session_workspace(claim, remote_session, settings),
         submission_options =
           [state_tool_capabilities: settings.state_tool_capabilities, workspace: workspace]
           |> maybe_submission_option(:platform_tools, settings.platform_tools)
           |> maybe_submission_option(:connected, settings.connected),
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

  defp ensure_submission(%{turn: %{submission: submission}} = claim, _remote, _settings)
       when is_map(submission),
       do: {:ok, claim}

  defp ensure_submission(_claim, _remote, _settings), do: {:error, :work_submission_missing}

  defp maybe_submission_option(options, _key, nil), do: options
  defp maybe_submission_option(options, key, value), do: Keyword.put(options, key, value)

  defp settings(options) when is_list(options) do
    allowed = [
      :api,
      :client,
      :connected,
      :lease_seconds,
      :max_block_ms,
      :max_polls,
      :monotonic_ms,
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
        api: Keyword.fetch!(options, :api),
        client: Keyword.fetch!(options, :client),
        connected: Keyword.get(options, :connected),
        lease_seconds: Keyword.get(options, :lease_seconds, 300),
        max_block_ms: Keyword.get(options, :max_block_ms, 30_000),
        max_polls: Keyword.get(options, :max_polls, 600),
        monotonic_ms:
          Keyword.get(options, :monotonic_ms, fn ->
            System.monotonic_time(:millisecond)
          end),
        poll_interval_ms: Keyword.get(options, :poll_interval_ms, 250),
        platform_tools: Keyword.get(options, :platform_tools),
        require_project_isolation: Keyword.get(options, :require_project_isolation, false),
        require_repository_read_only: Keyword.get(options, :require_repository_read_only, false),
        sleep: Keyword.get(options, :sleep, &Process.sleep/1),
        state_tool_capabilities:
          Keyword.get(
            options,
            :state_tool_capabilities,
            if(state_tools_endpoint, do: Capabilities.default(), else: nil)
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

  defp adapter?(api), do: is_atom(api) and not is_nil(api)

  # What the running system connected, when it says: Slack and GitHub, each on
  # or off. Absent, the model is told nothing rather than something false.
  defp valid_connected?(nil), do: true

  defp valid_connected?(%{github: github, slack: slack} = connected),
    do: map_size(connected) == 2 and is_boolean(github) and is_boolean(slack)

  defp valid_connected?(_connected), do: false

  defp validate_settings(settings) do
    safe_window = div(settings.lease_seconds * 1_000, 3)

    validations = [
      {adapter?(settings.api), :api},
      {valid_connected?(settings.connected), :connected},
      {is_integer(settings.lease_seconds) and settings.lease_seconds > 0, :lease_seconds},
      {is_integer(settings.max_block_ms) and settings.max_block_ms > 0 and
         settings.max_block_ms < safe_window, :max_block_ms},
      {is_integer(settings.max_polls) and settings.max_polls > 0, :max_polls},
      {is_function(settings.monotonic_ms, 0), :monotonic_ms},
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
       when is_binary(endpoint),
       do: Capabilities.valid?(capabilities)

  defp valid_state_tool_capabilities?(_settings), do: false

  defp valid_platform_tools?(tools), do: match?({:ok, _names}, PlatformTools.names(tools))

  defp valid_workspace_requirements?(requirements)
       when is_list(requirements) and length(requirements) <= 32 do
    names =
      Enum.map(requirements, fn
        %{"base_commit" => base_commit, "name" => name} = requirement
        when map_size(requirement) == 2 ->
          if Workspace.companion_name?(name) and GitObject.id?(base_commit),
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
