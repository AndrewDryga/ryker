defmodule Responder.Slack.WorkTarget do
  @moduledoc false

  import Ecto.Query

  alias Responder.Episodes.Episode
  alias Responder.Repo
  alias Responder.Slack.{IncidentRoom, TaskCard}

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

  @spec resolve_thread(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def resolve_thread("task-card:" <> _rest = work_ref, target) do
    with {:ok, resolved} <- task(work_ref) do
      exact_thread_target(resolved, target)
    end
  end

  def resolve_thread("incident-room:" <> _rest = work_ref, target) do
    with {:ok, resolved} <- incident(work_ref) do
      exact_thread_target(resolved, target)
    end
  end

  def resolve_thread(_work_ref, _target), do: {:error, :work_control_not_found}

  defp task(work_ref) do
    case Repo.one(
           from(card in TaskCard,
             join: episode in Episode,
             on: episode.id == card.episode_id,
             where: card.ref == ^work_ref,
             select: {card, episode}
           )
         ) do
      {%TaskCard{} = card, %Episode{} = episode} ->
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

      nil ->
        {:error, :work_control_not_found}
    end
  end

  defp incident(work_ref) do
    case Repo.one(
           from(room in IncidentRoom,
             join: episode in Episode,
             on: episode.id == room.episode_id,
             where: room.ref == ^work_ref,
             select: {room, episode}
           )
         ) do
      {%IncidentRoom{} = room, %Episode{} = episode} ->
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

      nil ->
        {:error, :work_control_not_found}
    end
  end

  defp exact_target(resolved, %{} = target, stored_thread_ref) do
    expected_conversation =
      "slack:#{resolved.workspace_ref}:#{resolved.channel_ref}"

    if Map.keys(target) |> Enum.sort() ==
         Enum.sort([:conversation_ref, :message_ref, :thread_ref, :transport]) and
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

  defp exact_thread_target(resolved, %{} = target) do
    expected_conversation = "slack:#{resolved.workspace_ref}:#{resolved.channel_ref}"

    if Map.keys(target) |> Enum.sort() ==
         Enum.sort([:conversation_ref, :message_ref, :thread_ref, :transport]) and
         target.transport == "slack" and target.conversation_ref == expected_conversation and
         is_binary(target.message_ref) and target.message_ref != "" and
         exact_thread?(target.thread_ref, resolved.output_thread_ref, target.message_ref) do
      {:ok, resolved}
    else
      {:error, :work_control_target_mismatch}
    end
  end

  defp exact_thread_target(_resolved, _target), do: {:error, :work_control_target_mismatch}

  defp exact_thread?(value, value, _message_ref), do: true
  defp exact_thread?(nil, stored, message_ref), do: stored == message_ref
  defp exact_thread?(_actual, _stored, _message_ref), do: false
end
