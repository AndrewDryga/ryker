defmodule Ryker.Work.Executor.Validation do
  @moduledoc """
  Freezes and delivers the verdict for one staged candidate.

  `ensure_validation_intent/6` runs the semantic validator, the presentation
  check, and the final preflight over the staged candidate and persists the
  verdict before anything reaches Coop. `validate_candidate/2` then sends that
  frozen verdict under its validation key, reconciling lost, uncertain, and
  cleanup-failed responses against the remote turn. The validation context
  builders live here as well.
  """

  alias Ryker.Artifacts.Outputs
  alias Ryker.Delivery.{PlatformActionCustody, Presentation}
  alias Ryker.Slack.Mentions
  alias Ryker.State.Records
  alias Ryker.Work.{Custody, FinalPreflight, StateBinding, Validator}
  alias Ryker.Work.Executor.{Remote, Turns}

  @terminal_turn_states Remote.terminal_turn_states()
  @turn_waiting_states Remote.turn_waiting_states()

  @doc false
  def ensure_validation_intent(
        %{turn: %{validation_intent: intent}} = claim,
        _message,
        _sha,
        _attempt,
        _artifacts,
        _settings
      )
      when is_map(intent),
      do: {:ok, claim}

  def ensure_validation_intent(claim, message, sha256, attempt, artifacts, settings) do
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

  @doc false
  def validate_candidate(claim, settings) do
    intent = claim.turn.validation_intent
    verdict = validation_verdict(intent)
    key = validation_key(claim.turn, verdict)

    case Remote.operation_by_key(settings, key) do
      :not_found -> mutate_validation(claim, key, verdict, settings)
      {:ok, operation} -> validation_from_operation(claim, operation, key, settings)
      {:error, _reason} = error -> error
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
        Remote.reconcile_after_transport(error, key, settings, fn operation ->
          validation_from_operation(claim, operation, key, settings)
        end)
    end
  end

  defp reconcile_validation_response(claim, key, reason, settings) do
    Remote.reconcile_after_transport(
      Remote.ambiguous_mutation(:validate_candidate, reason),
      key,
      settings,
      fn operation -> validation_from_operation(claim, operation, key, settings) end
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
    recover_validation_candidate(Turns.candidate_fields(candidate), claim, reason)
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
    uncertain_validation_candidate(Turns.candidate_fields(candidate), turn, claim, reason)
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
         Outputs.delivery_supported?(claim.episode)
       )
       |> Map.put_new("open_required_goals", Records.open_required_goals(claim.episode.id))
       |> Map.put("slack_mentions", Mentions.authority(claim.episode))
       |> Map.put("workspace", workspace)}
    end
  end

  @doc false
  def default_validation_context(claim) do
    context = claim.turn.submission["context"]

    %{
      "artifact_delivery_supported" => Outputs.delivery_supported?(claim.episode),
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
               Remote.api_call(settings, fn ->
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

  defp visible_reply_required?(%{"mode" => "full", "inputs" => %{"items" => items}}),
    do: Enum.any?(items, &(&1["current"] == true and human_input?(&1)))

  defp visible_reply_required?(%{
         "mode" => "continuation",
         "current_inputs" => %{"items" => items}
       }) do
    # The original human request was handled by an earlier accepted turn.
    # It must not force notifications for every later automated observation.
    Enum.any?(items, &human_input?/1)
  end

  defp visible_reply_required?(_context), do: false

  defp human_input?(%{"actor_ref" => actor_ref}) when is_binary(actor_ref),
    do: String.contains?(actor_ref, ":user:")

  defp human_input?(_input), do: false

  defp validation_verdict(%{"verdict" => "accept"}), do: :accept

  defp validation_verdict(%{"verdict" => "reject", "violations" => violations}),
    do: {:reject, violations}

  defp validation_key(turn, verdict) do
    verdict_name = if verdict == :accept, do: "accept", else: "reject"

    "ryker:work:validate:#{turn.id}:a#{turn.candidate_attempt}:g#{turn.validation_generation}:#{turn.candidate_sha256}:#{verdict_name}"
  end
end
