defmodule Ryker.Work.Executor.Validation do
  @moduledoc """
  Freezes and delivers the verdict for one staged candidate.

  `ensure_validation_intent/5` runs the semantic validator, the presentation
  check, and a snapshot of the staged candidate under the owner locks. It persists the
  verdict before anything reaches Coop. `validate_candidate/2` then sends that
  frozen verdict under its validation key, reconciling lost, uncertain, and
  cleanup-failed responses against the remote turn. The validation context
  builders live here as well.
  """
  alias Ryker.Artifacts
  alias Ryker.Coop
  alias Ryker.Delivery
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Work.{Custody, OperationKeys}
  alias Ryker.Work.Executor.{Remote, States}
  alias Ryker.Work.{StateBinding, Validator}

  @terminal_turn_states States.terminal()
  @turn_waiting_states States.waiting()

  @doc false
  def ensure_validation_intent(
        %{turn: %{validation_intent: intent}} = claim,
        _sha,
        _attempt,
        _artifacts,
        _settings
      )
      when is_map(intent),
      do: {:ok, claim}

  def ensure_validation_intent(claim, sha256, attempt, artifacts, settings) do
    requirements = workspace_requirements(claim)

    with {:ok, workspace} <- workspace_validation_context(claim, requirements, settings, sha256),
         {:ok, turn} <-
           Custody.prepare_candidate_validation(
             claim.episode.id,
             claim.turn.turn_ref,
             claim.lease_ref,
             sha256,
             attempt,
             &validate_and_freeze(&1, requirements, artifacts, workspace, settings)
           ) do
      {:ok, %{claim | turn: turn}}
    end
  end

  defp validate_and_freeze(claim, requirements, artifacts, workspace, settings) do
    with :ok <- unchanged_workspace_requirements(claim, requirements),
         :ok <- Ryker.Work.ThreadUpdates.before_final(claim) do
      case validate(claim, claim.turn.candidate, artifacts, workspace, settings) do
        {:accept, result} -> freeze_verdict(claim, :accept, result)
        {:reject, violations} -> freeze_verdict(claim, {:reject, violations}, nil)
        {:error, reason} -> {:error, reason}
      end
    else
      {:reject, notes} -> freeze_verdict(claim, {:reject, notes}, nil)
      {:error, reason} -> {:error, reason}
    end
  end

  defp unchanged_workspace_requirements(claim, requirements) do
    if workspace_requirements(claim) == requirements,
      do: :ok,
      else: {:error, :work_validation_context_changed}
  end

  defp freeze_verdict(claim, verdict, result) do
    Custody.prepare_validation(
      claim.episode.id,
      claim.turn.turn_ref,
      claim.lease_ref,
      claim.turn.candidate_sha256,
      claim.turn.candidate_attempt,
      verdict,
      result
    )
  end

  defp validate(claim, message, artifacts, workspace, settings) do
    with {:ok, context} <- validation_context(claim, artifacts, workspace, settings),
         {:accept, %{final: final, result: result}} <-
           Validator.validate(message, context, Repo.now!()),
         selected = Enum.filter(artifacts, &(&1["id"] in final.artifact_refs)),
         {:ok, _metadata} <- Artifacts.Outputs.prepare_metadata(selected),
         :ok <- Delivery.Presentation.validate(claim.episode, claim.turn, final) do
      {:accept, result}
    else
      {:reject, violations} ->
        {:reject, violations}

      {:error, {:invalid_delivery_presentation, reason}} ->
        {:reject, [Validator.presentation_violation(reason)]}

      {:error, {:invalid_work_output_artifacts, _field}} ->
        {:reject,
         [
           "Select at most five distinct chart or image attachments totaling no more than 8 MiB, then return the corrected candidate."
         ]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def validate_candidate(claim, settings) do
    intent = claim.turn.validation_intent
    verdict = validation_verdict(intent)
    key = OperationKeys.validate(claim.turn, verdict)

    case Remote.operation_by_key(settings, key) do
      :not_found -> mutate_validation(claim, key, verdict, settings)
      {:ok, operation} -> validation_from_operation(claim, operation, key, settings)
      {:error, reason} -> {:error, reason}
    end
  end

  defp mutate_validation(claim, key, verdict, settings) do
    case Remote.mutation_call(settings, :validate_candidate, key, fn ->
           validate_frozen_candidate(settings, claim, key, verdict)
         end) do
      {:ok, %{"turn" => remote_turn}} when is_map(remote_turn) ->
        case Remote.exact_remote_turn(
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
        Remote.reconcile_after_transport(
          error,
          key,
          settings,
          &validation_from_operation(claim, &1, key, settings)
        )
    end
  end

  defp reconcile_validation_response(claim, key, reason, settings) do
    Remote.reconcile_after_transport(
      Remote.ambiguous_mutation(:validate_candidate, reason),
      key,
      settings,
      &validation_from_operation(claim, &1, key, settings)
    )
  end

  defp validation_from_operation(claim, operation, key, settings) do
    case Remote.operation_resource(
           operation,
           "turn_validation",
           "ValidateTurnCandidate",
           key,
           settings,
           settings.max_polls
         ) do
      {:ok, turn_id} when turn_id == claim.turn.coop_turn_id ->
        Remote.fetch_bound_turn(claim, settings)

      {:ok, _turn_id} ->
        {:error, {:coop_protocol_error, :turn_identity}}

      {:confirmed_failed, reason} ->
        if validation_cleanup_failure?(reason),
          do: recover_validation_cleanup(claim, reason, settings),
          else: {:error, {:work_execution_blocked, reason}}

      {:uncertain, reason} ->
        reconcile_uncertain_validation(claim, reason, settings)

      {:error, reason} ->
        {:error, reason}
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
    with {:ok, remote_turn} <- Remote.fetch_bound_turn(claim, settings) do
      recover_validation_state(remote_turn, claim, reason)
    end
  end

  defp recover_validation_state(
         %{"state" => "awaiting_validation", "candidate" => candidate},
         claim,
         reason
       )
       when is_map(candidate) do
    recover_validation_candidate(Coop.Documents.candidate(candidate), claim, reason)
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
    with {:ok, remote_turn} <- Remote.fetch_bound_turn(claim, settings) do
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
    uncertain_validation_candidate(Coop.Documents.candidate(candidate), turn, claim, reason)
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

  defp validate_frozen_candidate(settings, claim, key, verdict) do
    with :ok <- authorize_thread_correction(claim, verdict) do
      settings.api.validate_frozen_candidate(
        settings.client,
        claim.session.coop_session_id,
        claim.turn.coop_turn_id,
        key,
        claim.turn.candidate_attempt,
        claim.turn.candidate_sha256,
        verdict
      )
    end
  end

  defp authorize_thread_correction(
         %{turn: %{thread_update_checkpoint: %{"reconsidered" => true}}} = claim,
         {:reject, _notes}
       ) do
    Ryker.Knowledge.KnowledgeSnapshot.authorize_session(claim.episode, claim.session)
  end

  defp authorize_thread_correction(_claim, _verdict), do: :ok

  defp validation_context(claim, artifacts, workspace, settings) do
    case settings.validation_context.(claim) do
      %{} = context -> complete_validation_context(context, claim, artifacts, workspace)
      {:ok, %{} = context} -> complete_validation_context(context, claim, artifacts, workspace)
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, {:invalid_work_executor, :validation_context}}
    end
  end

  defp complete_validation_context(context, claim, artifacts, workspace) do
    {:ok,
     context
     |> Map.put("artifact_metadata", Enum.map(artifacts, &Map.take(&1, ~w(id name))))
     |> Map.put("artifact_refs", Artifacts.Outputs.refs(artifacts))
     |> Map.put("execution_mode", Atom.to_string(claim.episode.execution_mode))
     |> Map.put_new(
       "artifact_delivery_supported",
       Artifacts.Outputs.delivery_supported?(claim.episode)
     )
     |> Map.put_new("open_required_goals", Records.open_required_goals(claim.episode.id))
     |> Map.put("slack_mentions", Custody.Delivery.answer_mentions(claim.episode, claim.turn))
     |> Map.put("workspace", workspace)}
  end

  defp workspace_validation_context(_claim, [], _settings, _sha256), do: {:ok, nil}

  defp workspace_validation_context(claim, goals, settings, sha256) do
    with true <- function_exported?(settings.api, :get_changes, 2),
         {:ok, changes} <-
           Remote.api_call(settings, fn ->
             candidate_changes(claim, settings, sha256)
           end),
         {:ok, prepared} <- prepare_workspace_changes(changes, goals) do
      purpose = get_in(claim.session.workspace_task || %{}, ["purpose"]) || "implementation"

      source_commit =
        get_in(claim.turn.submission || %{}, [
          "context",
          "workspace",
          "source",
          "selected_commit"
        ]) || changes["base_commit"]

      {:ok,
       prepared
       |> Map.put("purpose", purpose)
       |> Map.put("admitted_source_commit", source_commit)
       |> compare_submitted_input(claim.session, changes)}
    else
      false -> {:error, {:invalid_work_executor, :workspace_changes_api}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp candidate_changes(claim, settings, sha256) do
    if operator_verification?(claim.session.workspace_task) do
      if function_exported?(settings.api, :get_verification_changes, 4) do
        settings.api.get_verification_changes(
          settings.client,
          claim.session.coop_session_id,
          claim.turn.coop_turn_id,
          sha256
        )
      else
        {:error, {:coop_upgrade_required, :verification_source}}
      end
    else
      settings.api.get_changes(settings.client, claim.session.coop_session_id)
    end
  end

  defp operator_verification?(%{
         "offer_ref" => "operator-fleet-job:" <> _id,
         "purpose" => "verification"
       }),
       do: true

  defp operator_verification?(_task), do: false

  defp compare_submitted_input(workspace, session, changes) do
    task = session.workspace_task

    if operator_verification?(task) do
      head = get_in(session.worker_job_document || %{}, ["source", "binding", "selected_commit"])

      expected =
        task["verification_input_sha256"] ||
          clean_source_digest(head, workspace["admitted_source_tree"])

      Map.put(
        workspace,
        "submitted_input_unchanged",
        is_binary(expected) and expected == changes["working_source_digest"]
      )
    else
      workspace
    end
  end

  defp clean_source_digest(head, tree)
       when is_binary(head) and is_binary(tree),
       do: Ryker.Crypto.sha256_hex(head <> "\n" <> tree <> "\n" <> tree <> "\n")

  defp clean_source_digest(_head, _tree), do: nil

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
         {:ok, admitted_source_tree} <-
           optional_workspace_identity(changes["admitted_source_tree"]),
         {:ok, committed_count} <- workspace_change_count(changes["committed"]),
         {:ok, staged_count} <- workspace_change_count(changes["staged"]),
         {:ok, unstaged_count} <- workspace_change_count(changes["unstaged"]),
         {:ok, untracked_count} <- workspace_change_count(changes["untracked"]),
         {:ok, conflict_count} <- workspace_change_count(changes["conflicts"]),
         {:ok, repository} <- repository_write_goal_repository(goals) do
      {:ok,
       %{
         "admitted_source_tree" => admitted_source_tree,
         "base_commit" => base_commit,
         "committed_count" => committed_count,
         "conflict_count" => conflict_count,
         "fork_head" => fork_head,
         "fork_tree" => fork_tree,
         "goal_ids" => Enum.map(goals, & &1["id"]),
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

  defp validation_verdict(%{"verdict" => "accept"}), do: :accept

  defp validation_verdict(%{"verdict" => "reject", "violations" => violations}),
    do: {:reject, violations}
end
