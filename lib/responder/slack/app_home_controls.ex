defmodule Responder.Slack.AppHomeControls do
  @moduledoc """
  Applies operator-only App Home controls through existing typed state APIs.

  A click carries only an opaque resource reference. Membership, operator
  authority, current lifecycle state, and the refreshed view are all resolved
  again by the host.
  """

  alias Responder.Slack.{HomeEvent, HomeInteraction}

  @spec handle(HomeInteraction.t(), map()) :: {:ok, map()} | {:error, term()}
  def handle(%HomeInteraction{} = interaction, %{} = options) do
    with {:ok, true} <- allowed?(interaction, options),
         :ok <- operator?(interaction, options),
         {:ok, outcome} <- dispatch(interaction, options),
         {:ok, _refresh} <- refresh(interaction, options) do
      {:ok, %{outcome: outcome, resource_ref: interaction.resource_ref}}
    else
      {:ok, false} -> {:ok, %{outcome: :denied}}
      {:error, :operator_required} -> {:ok, %{outcome: :denied}}
      {:error, _reason} = error -> error
    end
  end

  def handle(_interaction, _options), do: {:error, {:invalid_app_home_control, :request}}

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

  defp dispatch(
         %HomeInteraction{
           action: :disable_behavior,
           actor_ref: actor_ref,
           resource_ref: "behavior:" <> _ = ref,
           workspace_ref: workspace_ref
         },
         options
       ),
       do: behavior_status(options, ref, :disabled, actor_ref, workspace_ref)

  defp dispatch(
         %HomeInteraction{
           action: :enable_behavior,
           actor_ref: actor_ref,
           resource_ref: "behavior:" <> _ = ref,
           workspace_ref: workspace_ref
         },
         options
       ),
       do: behavior_status(options, ref, :active, actor_ref, workspace_ref)

  defp dispatch(
         %HomeInteraction{
           action: :delete_behavior,
           actor_ref: actor_ref,
           resource_ref: "behavior:" <> _ = ref,
           workspace_ref: workspace_ref
         },
         options
       ),
       do: behavior_status(options, ref, :deleted, actor_ref, workspace_ref)

  defp dispatch(
         %HomeInteraction{
           action: :pause_schedule,
           resource_ref: "schedule:" <> _ = ref,
           workspace_ref: workspace_ref
         },
         options
       ),
       do: binary(options, :set_schedule_status, ref, :paused, workspace_ref)

  defp dispatch(
         %HomeInteraction{
           action: :resume_schedule,
           resource_ref: "schedule:" <> _ = ref,
           workspace_ref: workspace_ref
         },
         options
       ),
       do: binary(options, :set_schedule_status, ref, :active, workspace_ref)

  defp dispatch(
         %HomeInteraction{
           action: :delete_schedule,
           resource_ref: "schedule:" <> _ = ref,
           workspace_ref: workspace_ref
         },
         options
       ),
       do: binary(options, :set_schedule_status, ref, :deleted, workspace_ref)

  defp dispatch(_interaction, _options), do: {:error, :app_home_control_mismatch}

  defp memory_review_action(:keep_memory_review), do: :keep
  defp memory_review_action(:merge_memory_review), do: :merge
  defp memory_review_action(:forget_memory_review), do: :forget

  defp resolve_memory_review(options, ref, review_action, actor_ref, workspace_ref) do
    case Map.get(options, :resolve_memory_review) do
      callback when is_function(callback, 4) ->
        callback.(ref, review_action, actor_ref, "slack:#{workspace_ref}")
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

  defp behavior_status(options, ref, status, actor_ref, workspace_ref) do
    case Map.get(options, :set_behavior_status) do
      callback when is_function(callback, 4) ->
        case callback.(ref, status, actor_ref, workspace_ref) do
          {:ok, resource} ->
            {:ok, resource.status}

          {:error, reason}
          when reason in [
                 :behavior_not_found,
                 :behavior_workspace_mismatch,
                 :behavior_terminal,
                 :behavior_unauthorized
               ] ->
            {:ok, :invalid}

          {:error, _reason} = error ->
            error

          _invalid ->
            {:error, {:invalid_app_home_control, :set_behavior_status}}
        end

      _missing ->
        {:error, {:invalid_app_home_control, :set_behavior_status}}
    end
  end

  defp binary(options, key, ref, status, workspace_ref) do
    case Map.get(options, key) do
      callback when is_function(callback, 3) ->
        case callback.(ref, status, workspace_ref) do
          {:ok, _resource} ->
            {:ok, status}

          {:error, reason}
          when reason in [
                 :behavior_not_found,
                 :behavior_workspace_mismatch,
                 :behavior_terminal,
                 :schedule_not_found,
                 :schedule_scope_mismatch,
                 :schedule_terminal
               ] ->
            {:ok, :invalid}

          {:error, _reason} = error ->
            error

          _invalid ->
            {:error, {:invalid_app_home_control, key}}
        end

      _missing ->
        {:error, {:invalid_app_home_control, key}}
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
end
