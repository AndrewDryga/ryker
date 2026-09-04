defmodule Responder.Slack.AppHomeControls do
  @moduledoc """
  Applies operator-only App Home controls through existing typed state APIs.

  A click carries only an opaque resource reference. Membership, operator
  authority, current lifecycle state, and the refreshed view are all resolved
  again by the host.
  """

  alias Responder.Slack.{HomeEvent, HomeInteraction, HomeSubmission}

  @spec handle(HomeInteraction.t(), map()) :: {:ok, map()} | {:error, term()}
  def handle(%HomeInteraction{} = interaction, %{} = options) do
    handle_control(interaction, options)
  end

  def handle(%HomeSubmission{} = submission, %{} = options) do
    handle_control(submission, options)
  end

  def handle(_interaction, _options), do: {:error, {:invalid_app_home_control, :request}}

  defp handle_control(interaction, options) do
    with {:ok, true} <- allowed?(interaction, options),
         :ok <- operator?(interaction, options),
         :ok <- resource_authorized?(interaction, options),
         {:ok, outcome} <- dispatch(interaction, options),
         :ok <- refresh_if_needed(interaction, outcome, options) do
      {:ok, %{outcome: outcome, resource_ref: interaction.resource_ref}}
    else
      {:ok, false} -> {:ok, %{outcome: :denied}}
      {:error, :operator_required} -> {:ok, %{outcome: :denied}}
      {:error, :app_home_resource_not_visible} -> {:ok, %{outcome: :denied}}
      {:error, _reason} = error -> error
    end
  end

  defp resource_authorized?(interaction, options) do
    case Map.get(options, :authorize_resource) do
      callback when is_function(callback, 1) ->
        case callback.(interaction) do
          :ok -> :ok
          {:error, _reason} = error -> error
          _invalid -> {:error, {:invalid_app_home_control, :authorize_resource}}
        end

      _missing ->
        {:error, {:invalid_app_home_control, :authorize_resource}}
    end
  end

  defp allowed?(interaction, options) do
    with directory when is_atom(directory) <- Map.get(options, :directory),
         client <- Map.get(options, :client),
         true <- function_exported?(directory, :user_allowed, 3) do
      case directory.user_allowed(client, interaction.actor_ref, interaction.workspace_ref) do
        {:ok, allowed} when is_boolean(allowed) -> {:ok, allowed}
        {:error, _reason} = error -> error
        _invalid -> {:error, {:invalid_app_home_control, :directory}}
      end
    else
      _invalid -> {:error, {:invalid_app_home_control, :directory}}
    end
  end

  defp operator?(interaction, options) do
    case Map.get(options, :operators) do
      %MapSet{} = operators ->
        if MapSet.member?(operators, interaction.actor_ref),
          do: :ok,
          else: {:error, :operator_required}

      _invalid ->
        {:error, {:invalid_app_home_control, :operators}}
    end
  end

  defp dispatch(
         %HomeInteraction{
           action: :forget_memory,
           actor_ref: actor_ref,
           resource_ref: "memory:" <> _ = ref,
           workspace_ref: workspace_ref
         },
         options
       ),
       do: forget_memory(options, ref, actor_ref, workspace_ref)

  defp dispatch(
         %HomeInteraction{
           action: :edit_memory_review,
           actor_ref: actor_ref,
           resource_ref: "memory-review:" <> _ = ref,
           trigger_ref: trigger_ref,
           workspace_ref: workspace_ref
         },
         options
       ),
       do: open_memory_review_editor(options, ref, trigger_ref, actor_ref, workspace_ref)

  defp dispatch(
         %HomeSubmission{
           action: :edit_memory_review,
           actor_ref: actor_ref,
           replacement: replacement,
           resource_ref: "memory-review:" <> _ = ref,
           workspace_ref: workspace_ref
         },
         options
       ) do
    resolve_memory_review(options, ref, :edit, actor_ref, workspace_ref, replacement)
  end

  defp dispatch(%HomeInteraction{action: action, resource_ref: "behavior:" <> _}, _options)
       when action in [:disable_behavior, :enable_behavior, :delete_behavior],
       do: {:ok, :invalid}

  defp dispatch(
         %HomeInteraction{
           action: action,
           actor_ref: actor_ref,
           resource_ref: "memory-review:" <> _ = ref,
           workspace_ref: workspace_ref
         },
         options
       )
       when action in [:keep_memory_review, :merge_memory_review, :forget_memory_review] do
    review_action = memory_review_action(action)

    resolve_memory_review(options, ref, review_action, actor_ref, workspace_ref)
  end

  defp dispatch(%HomeInteraction{action: action, resource_ref: "schedule:" <> _}, _options)
       when action in [:pause_schedule, :resume_schedule, :delete_schedule],
       do: {:ok, :invalid}

  defp dispatch(
         %HomeInteraction{
           action: :disable_behavior,
           actor_ref: actor_ref,
           event_ref: action_ref,
           resource_ref: "behavior-control:" <> _ = value,
           workspace_ref: workspace_ref
         },
         options
       ) do
    with {:ok, ref, revision} <- versioned_resource(value, "behavior") do
      behavior_status(options, ref, :disabled, revision, actor_ref, workspace_ref, action_ref)
    end
  end

  defp dispatch(
         %HomeInteraction{
           action: :enable_behavior,
           actor_ref: actor_ref,
           event_ref: action_ref,
           resource_ref: "behavior-control:" <> _ = value,
           workspace_ref: workspace_ref
         },
         options
       ) do
    with {:ok, ref, revision} <- versioned_resource(value, "behavior") do
      behavior_status(options, ref, :active, revision, actor_ref, workspace_ref, action_ref)
    end
  end

  defp dispatch(
         %HomeInteraction{
           action: :delete_behavior,
           actor_ref: actor_ref,
           event_ref: action_ref,
           resource_ref: "behavior-control:" <> _ = value,
           workspace_ref: workspace_ref
         },
         options
       ) do
    with {:ok, ref, revision} <- versioned_resource(value, "behavior") do
      behavior_status(options, ref, :deleted, revision, actor_ref, workspace_ref, action_ref)
    end
  end

  defp dispatch(
         %HomeInteraction{
           action: :pause_schedule,
           actor_ref: actor_ref,
           event_ref: action_ref,
           resource_ref: "schedule-control:" <> _ = value,
           workspace_ref: workspace_ref
         },
         options
       ) do
    with {:ok, ref, revision} <- versioned_resource(value, "schedule") do
      schedule_status(options, ref, :paused, revision, actor_ref, workspace_ref, action_ref)
    end
  end

  defp dispatch(
         %HomeInteraction{
           action: :resume_schedule,
           actor_ref: actor_ref,
           event_ref: action_ref,
           resource_ref: "schedule-control:" <> _ = value,
           workspace_ref: workspace_ref
         },
         options
       ) do
    with {:ok, ref, revision} <- versioned_resource(value, "schedule") do
      schedule_status(options, ref, :active, revision, actor_ref, workspace_ref, action_ref)
    end
  end

  defp dispatch(
         %HomeInteraction{
           action: :delete_schedule,
           actor_ref: actor_ref,
           event_ref: action_ref,
           resource_ref: "schedule-control:" <> _ = value,
           workspace_ref: workspace_ref
         },
         options
       ) do
    with {:ok, ref, revision} <- versioned_resource(value, "schedule") do
      schedule_status(options, ref, :deleted, revision, actor_ref, workspace_ref, action_ref)
    end
  end

  defp dispatch(
         %HomeInteraction{
           action: :run_schedule,
           actor_ref: actor_ref,
           event_ref: action_ref,
           resource_ref: "schedule:" <> _ = ref,
           workspace_ref: workspace_ref
         },
         options
       ),
       do: run_schedule(options, ref, actor_ref, workspace_ref, action_ref)

  defp dispatch(
         %HomeInteraction{
           action: action,
           actor_ref: actor_ref,
           event_ref: action_ref,
           resource_ref: "publication-recovery:" <> _ = value,
           workspace_ref: workspace_ref
         },
         options
       )
       when action in [:retry_publication, :update_publication, :discard_publication] do
    with {:ok, publication_ref, generation} <- publication_recovery(value) do
      recover_publication(
        options,
        publication_ref,
        publication_action(action),
        generation,
        actor_ref,
        workspace_ref,
        action_ref
      )
    end
  end

  defp dispatch(
         %HomeInteraction{
           action: :discard_workspace,
           actor_ref: actor_ref,
           event_ref: action_ref,
           resource_ref: "responder-work-control:" <> value,
           workspace_ref: workspace_ref
         },
         options
       ) do
    with {:ok, ref, fingerprint} <- retained_workspace_control(value) do
      discard_workspace(
        options,
        ref,
        fingerprint,
        actor_ref,
        workspace_ref,
        action_ref
      )
    end
  end

  defp dispatch(%HomeInteraction{action: :open_resource}, _options), do: {:ok, :opened}

  defp dispatch(_interaction, _options), do: {:error, :app_home_control_mismatch}

  defp memory_review_action(:keep_memory_review), do: :keep
  defp memory_review_action(:merge_memory_review), do: :merge
  defp memory_review_action(:forget_memory_review), do: :forget

  defp publication_action(:retry_publication), do: :retry
  defp publication_action(:update_publication), do: :update
  defp publication_action(:discard_publication), do: :discard

  defp resolve_memory_review(
         options,
         ref,
         review_action,
         actor_ref,
         workspace_ref,
         replacement \\ nil
       ) do
    case Map.get(options, :resolve_memory_review) do
      callback when is_function(callback, 5) ->
        callback.(ref, review_action, actor_ref, "slack:#{workspace_ref}", replacement)
        |> memory_review_result(review_action)

      _missing ->
        {:error, {:invalid_app_home_control, :resolve_memory_review}}
    end
  end

  defp memory_review_result({:ok, _result}, review_action), do: {:ok, review_action}

  defp memory_review_result({:error, reason}, _review_action)
       when reason in [
              :memory_review_not_found,
              :memory_review_workspace_mismatch,
              :memory_review_stale,
              :memory_review_cannot_merge,
              :memory_review_conflict,
              :memory_review_unauthorized
            ],
       do: {:ok, :invalid}

  defp memory_review_result({:error, _reason} = error, _review_action), do: error

  defp memory_review_result(_invalid, _review_action),
    do: {:error, {:invalid_app_home_control, :resolve_memory_review}}

  defp open_memory_review_editor(options, ref, trigger_ref, actor_ref, workspace_ref) do
    case Map.get(options, :open_memory_review_editor) do
      callback when is_function(callback, 4) and is_binary(trigger_ref) ->
        case callback.(ref, trigger_ref, actor_ref, "slack:#{workspace_ref}") do
          :ok ->
            {:ok, :editing}

          {:error, reason}
          when reason in [
                 :memory_review_not_found,
                 :memory_review_unauthorized,
                 :memory_review_cannot_edit
               ] ->
            {:ok, :invalid}

          {:error, _reason} = error ->
            error

          _invalid ->
            {:error, {:invalid_app_home_control, :open_memory_review_editor}}
        end

      callback when is_function(callback, 4) ->
        {:ok, :invalid}

      _missing ->
        {:error, {:invalid_app_home_control, :open_memory_review_editor}}
    end
  end

  defp forget_memory(options, ref, actor_ref, workspace_ref) do
    case Map.get(options, :forget_memory) do
      callback when is_function(callback, 3) ->
        case callback.(ref, actor_ref, workspace_ref) do
          {:ok, _resource} ->
            {:ok, :forgotten}

          {:error, reason}
          when reason in [
                 :memory_not_found,
                 :memory_workspace_mismatch,
                 :memory_terminal,
                 :memory_unauthorized
               ] ->
            {:ok, :invalid}

          {:error, _reason} = error ->
            error

          _invalid ->
            {:error, {:invalid_app_home_control, :forget_memory}}
        end

      _missing ->
        {:error, {:invalid_app_home_control, :forget_memory}}
    end
  end

  defp behavior_status(options, ref, status, revision, actor_ref, workspace_ref, action_ref) do
    case Map.get(options, :set_behavior_status) do
      callback when is_function(callback, 6) ->
        callback.(ref, status, revision, actor_ref, workspace_ref, action_ref)
        |> action_result(status, :set_behavior_status, [
          :behavior_not_found,
          :behavior_workspace_mismatch,
          :behavior_revision_stale,
          :behavior_terminal,
          :behavior_unauthorized,
          :operator_action_conflict
        ])

      _missing ->
        {:error, {:invalid_app_home_control, :set_behavior_status}}
    end
  end

  defp schedule_status(options, ref, status, revision, actor_ref, workspace_ref, action_ref) do
    case Map.get(options, :set_schedule_status) do
      callback when is_function(callback, 6) ->
        callback.(ref, status, revision, actor_ref, workspace_ref, action_ref)
        |> action_result(status, :set_schedule_status, [
          :schedule_not_found,
          :schedule_scope_mismatch,
          :schedule_revision_stale,
          :schedule_terminal,
          :operator_action_conflict
        ])

      _missing ->
        {:error, {:invalid_app_home_control, :set_schedule_status}}
    end
  end

  defp run_schedule(options, ref, actor_ref, workspace_ref, action_ref) do
    case Map.get(options, :run_schedule) do
      callback when is_function(callback, 4) ->
        callback.(ref, actor_ref, workspace_ref, action_ref)
        |> action_result(:started, :run_schedule, [
          :schedule_not_found,
          :schedule_scope_mismatch,
          :schedule_terminal,
          :schedule_occurrence_active
        ])

      _missing ->
        {:error, {:invalid_app_home_control, :run_schedule}}
    end
  end

  defp recover_publication(
         options,
         ref,
         action,
         generation,
         actor_ref,
         workspace_ref,
         action_ref
       ) do
    case Map.get(options, :recover_publication) do
      callback when is_function(callback, 6) ->
        callback.(ref, action, generation, actor_ref, workspace_ref, action_ref)
        |> action_result(action, :recover_publication, [
          :publication_not_found,
          :publication_recovery_generation_stale,
          :publication_recovery_lease_active,
          :publication_recovery_not_allowed,
          :publication_workspace_mismatch,
          :operator_action_conflict
        ])

      _missing ->
        {:error, {:invalid_app_home_control, :recover_publication}}
    end
  end

  defp discard_workspace(
         options,
         ref,
         fingerprint,
         actor_ref,
         workspace_ref,
         action_ref
       ) do
    case Map.get(options, :discard_workspace) do
      callback when is_function(callback, 5) ->
        callback.(ref, fingerprint, actor_ref, workspace_ref, action_ref)
        |> action_result(:discard_requested, :discard_workspace, [
          :retention_session_not_found,
          :retention_session_workspace_mismatch,
          :retention_discard_plan_stale,
          :retention_dirty_workspace,
          :retention_unmerged_discard_unavailable,
          :retention_operator_action_conflict
        ])

      _missing ->
        {:error, {:invalid_app_home_control, :discard_workspace}}
    end
  end

  defp action_result({:ok, %{outcome: %{"status" => "expired"}}}, _outcome, _key, _settled),
    do: {:ok, :invalid}

  defp action_result({:ok, _result}, outcome, _key, _settled), do: {:ok, outcome}

  defp action_result({:error, reason} = error, _outcome, _key, settled) do
    if reason in settled, do: {:ok, :invalid}, else: error
  end

  defp action_result(_invalid, _outcome, key, _settled),
    do: {:error, {:invalid_app_home_control, key}}

  defp publication_recovery("publication-recovery:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [id, generation] ->
        case Integer.parse(generation) do
          {generation, ""} when generation > 0 -> {:ok, "publication:#{id}", generation}
          _invalid -> {:error, :app_home_control_mismatch}
        end

      _invalid ->
        {:error, :app_home_control_mismatch}
    end
  end

  defp retained_workspace_control(value) do
    case String.split(value, ":") do
      parts when length(parts) >= 4 ->
        fingerprint = List.last(parts)
        ref = parts |> Enum.drop(-1) |> Enum.join(":")

        if String.starts_with?(ref, "responder-work:") and
             Regex.match?(~r/\A[0-9a-f]{64}\z/, fingerprint),
           do: {:ok, ref, fingerprint},
           else: {:error, :app_home_control_mismatch}

      _invalid ->
        {:error, :app_home_control_mismatch}
    end
  end

  defp versioned_resource(value, kind) do
    prefix = "#{kind}-control:"

    with true <- is_binary(value) and String.starts_with?(value, prefix),
         rest <- String.replace_prefix(value, prefix, ""),
         parts when length(parts) >= 2 <- String.split(rest, ":"),
         revision_text <- List.last(parts),
         {revision, ""} when revision > 0 <- Integer.parse(revision_text),
         ref <- parts |> Enum.drop(-1) |> Enum.join(":"),
         true <- String.starts_with?(ref, "#{kind}:") do
      {:ok, ref, revision}
    else
      _invalid -> {:error, :app_home_control_mismatch}
    end
  end

  defp refresh(interaction, options) do
    case Map.get(options, :refresh_home) do
      callback when is_function(callback, 1) ->
        callback.(%HomeEvent{
          actor_ref: interaction.actor_ref,
          event_ref: interaction.event_ref,
          workspace_ref: interaction.workspace_ref
        })

      _missing ->
        {:error, {:invalid_app_home_control, :refresh_home}}
    end
  end

  defp refresh_if_needed(_interaction, outcome, _options) when outcome in [:editing, :opened],
    do: :ok

  defp refresh_if_needed(interaction, _outcome, options) do
    case refresh(interaction, options) do
      {:ok, _refresh} -> :ok
      {:error, _reason} = error -> error
      _invalid -> {:error, {:invalid_app_home_control, :refresh_home}}
    end
  end
end
