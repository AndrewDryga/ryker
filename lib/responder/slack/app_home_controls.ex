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
           resource_ref: "memory:" <> _ = ref,
           workspace_ref: workspace_ref
         },
         options
       ),
       do: unary(options, :forget_memory, ref, workspace_ref, :forgotten)

  defp dispatch(
         %HomeInteraction{
           action: :disable_behavior,
           resource_ref: "behavior:" <> _ = ref,
           workspace_ref: workspace_ref
         },
         options
       ),
       do: binary(options, :set_behavior_status, ref, :disabled, workspace_ref)

  defp dispatch(
         %HomeInteraction{
           action: :enable_behavior,
           resource_ref: "behavior:" <> _ = ref,
           workspace_ref: workspace_ref
         },
         options
       ),
       do: binary(options, :set_behavior_status, ref, :active, workspace_ref)

  defp dispatch(
         %HomeInteraction{
           action: :delete_behavior,
           resource_ref: "behavior:" <> _ = ref,
           workspace_ref: workspace_ref
         },
         options
       ),
       do: binary(options, :set_behavior_status, ref, :deleted, workspace_ref)

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

  defp unary(options, key, ref, workspace_ref, outcome) do
    case Map.get(options, key) do
      callback when is_function(callback, 2) ->
        case callback.(ref, workspace_ref) do
          {:ok, _resource} ->
            {:ok, outcome}

          {:error, reason}
          when reason in [:memory_not_found, :memory_workspace_mismatch, :memory_terminal] ->
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
