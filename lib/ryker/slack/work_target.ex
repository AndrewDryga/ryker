defmodule Ryker.Slack.WorkTarget do
  @moduledoc false
  alias Ryker.ConversationRef
  alias Ryker.Episodes
  alias Ryker.Maps
  alias Ryker.Repo
  alias Ryker.Slack.{IncidentRoom, TaskCard}

  @spec resolve(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def resolve("task-card:" <> _rest = work_ref, target) do
    with {:ok, resolved} <- task(work_ref) do
      exact_target(resolved, target, resolved.output_thread_ref)
    end
  end

  def resolve("incident-room:" <> _rest = work_ref, target) do
    with {:ok, resolved} <- incident(work_ref) do
      exact_target(resolved, target, resolved.output_thread_ref)
    end
  end

  def resolve(_work_ref, _target), do: {:error, :work_control_not_found}

  defp task(work_ref) do
    found =
      work_ref |> TaskCard.Query.by_ref() |> TaskCard.Query.select_with_episode() |> Repo.fetch()

    case found do
      {:ok, {%TaskCard{} = card, %Episodes.Episode{} = episode}} ->
        {:ok,
         %{
           card_message_ref: card.message_ref,
           channel_ref: card.channel_ref,
           episode: episode,
           kind: :task,
           output_thread_ref: card.thread_ref,
           work_ref: card.ref,
           workspace_ref: card.workspace_ref
         }}

      {:error, :not_found} ->
        {:error, :work_control_not_found}
    end
  end

  defp incident(work_ref) do
    found =
      work_ref
      |> IncidentRoom.Query.by_ref()
      |> IncidentRoom.Query.select_with_episode()
      |> Repo.fetch()

    case found do
      {:ok, {%IncidentRoom{} = room, %Episodes.Episode{} = episode}} ->
        {:ok,
         %{
           card_message_ref: room.root_message_ref,
           channel_ref: room.channel_ref,
           episode: episode,
           kind: :incident,
           output_thread_ref: room.root_message_ref,
           work_ref: room.ref,
           workspace_ref: room.workspace_ref
         }}

      {:error, :not_found} ->
        {:error, :work_control_not_found}
    end
  end

  defp exact_target(resolved, %{} = target, stored_thread_ref) do
    expected_conversation =
      ConversationRef.slack(resolved.workspace_ref, resolved.channel_ref)

    if Maps.exact_keys?(target, [:conversation_ref, :message_ref, :thread_ref, :transport]) and
         target.transport == "slack" and target.conversation_ref == expected_conversation and
         target.message_ref == resolved.card_message_ref and
         exact_thread?(target.thread_ref, stored_thread_ref, resolved.card_message_ref) do
      {:ok, resolved}
    else
      {:error, :work_control_target_mismatch}
    end
  end

  defp exact_target(_resolved, _target, _stored_thread_ref),
    do: {:error, :work_control_target_mismatch}

  defp exact_thread?(value, value, _message_ref), do: true
  defp exact_thread?(nil, stored, message_ref), do: stored == message_ref
  defp exact_thread?(_actual, _stored, _message_ref), do: false
end
