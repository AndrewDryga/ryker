defmodule Responder.Slack.ThreadStatusProjection do
  @moduledoc """
  Projects durable ingress and episode ownership onto Slack assistant threads.

  The database remains authoritative. Recent terminal rows are included so a
  restarted worker can clear a status that Slack still displays.
  """

  import Ecto.Query

  alias Responder.Episodes.Episode
  alias Responder.Ingress.Inbox.Entry
  alias Responder.Repo

  @recent_terminal_seconds 24 * 60 * 60
  @maximum_rows 1_000

  @doc false
  @spec phases() :: [atom()]
  def phases,
    do: [
      :blocked,
      :admitting,
      :admission_retry,
      :queued,
      :delivery,
      :working,
      :waiting_for_input,
      :waiting_for_event,
      :clear
    ]

  @spec snapshot(String.t()) :: {:ok, [map()]} | {:error, term()}
  def snapshot(workspace_ref) when is_binary(workspace_ref) and workspace_ref != "" do
    cutoff = DateTime.add(DateTime.utc_now(), -@recent_terminal_seconds, :second)

    {:ok,
     targets(
       recent_entries(workspace_ref, cutoff),
       recent_episodes(workspace_ref, cutoff),
       workspace_ref
     )}
  rescue
    error -> {:error, {:slack_thread_status_projection_failed, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:slack_thread_status_projection_failed, kind, inspect(reason)}}
  end

  def snapshot(_workspace_ref), do: {:error, {:invalid_slack_thread_status, :workspace_ref}}

  defp recent_entries(workspace_ref, cutoff) do
    Repo.all(
      from(entry in Entry,
        where:
          entry.source_kind == "slack" and entry.source_ref == ^workspace_ref and
            entry.destination_transport == "slack" and entry.execution_mode == :live and
            (entry.status in [:pending, :blocked] or entry.updated_at >= ^cutoff),
        order_by: [desc: entry.updated_at],
        limit: @maximum_rows
      )
    )
  end

  defp recent_episodes(workspace_ref, cutoff) do
    Repo.all(
      from(episode in Episode,
        where:
          episode.destination_transport == "slack" and episode.execution_mode == :live and
            fragment(
              "split_part(?, ':', 1) = 'slack' AND split_part(?, ':', 2) = ?",
              episode.destination_conversation_ref,
              episode.destination_conversation_ref,
              ^workspace_ref
            ) and
            (episode.state in [:working, :waiting_for_input, :waiting_for_event] or
               episode.updated_at >= ^cutoff),
        order_by: [desc: episode.updated_at],
        limit: @maximum_rows
      )
    )
  end

  @doc false
  @spec targets([Entry.t()], [Episode.t()], String.t()) :: [map()]
  def targets(entries, episodes, workspace_ref)
      when is_list(entries) and is_list(episodes) and is_binary(workspace_ref) do
    (Enum.flat_map(entries, &entry_candidate(&1, workspace_ref)) ++
       Enum.flat_map(episodes, &episode_candidate(&1, workspace_ref)))
    |> Enum.group_by(& &1.key)
    |> Enum.map(fn {_key, candidates} -> Enum.max_by(candidates, & &1.priority) end)
    |> Enum.map(&Map.drop(&1, [:key, :priority]))
    |> Enum.sort_by(&{&1.channel_ref, &1.thread_ref})
  end

  defp entry_candidate(%Entry{execution_mode: :live} = entry, workspace_ref) do
    with {:ok, key} <- destination(entry, workspace_ref),
         {:ok, phase, status, priority} <- entry_status(entry) do
      [
        Map.merge(candidate(key, phase, status, priority), %{
          origin_kind: "input",
          origin_id: entry.id
        })
      ]
    else
      _invalid -> []
    end
  end

  defp entry_candidate(_entry, _workspace_ref), do: []

  defp episode_candidate(%Episode{execution_mode: :live} = episode, workspace_ref) do
    with {:ok, key} <- destination(episode, workspace_ref),
         {:ok, phase, status, priority} <- episode_status(episode) do
      [
        Map.merge(candidate(key, phase, status, priority), %{
          origin_kind: "episode",
          origin_id: episode.id
        })
      ]
    else
      _invalid -> []
    end
  end

  defp episode_candidate(_episode, _workspace_ref), do: []

  defp entry_status(%Entry{status: :blocked}),
    do: {:ok, :blocked, "", 110}

  defp entry_status(%Entry{status: :pending, lease_ref: lease_ref})
       when is_binary(lease_ref) and lease_ref != "",
       do: {:ok, :admitting, "is deciding how to respond...", 100}

  defp entry_status(%Entry{status: :pending, next_attempt_at: %DateTime{}}),
    do: {:ok, :admission_retry, "is waiting to retry admission...", 90}

  defp entry_status(%Entry{status: :pending}), do: {:ok, :queued, "is queued...", 80}

  defp entry_status(%Entry{status: status}) when status in [:decided, :superseded],
    do: {:ok, :clear, "", 10}

  defp entry_status(_entry), do: :ignore

  defp episode_status(%Episode{state: :working, owner_kind: :delivery}),
    do: {:ok, :delivery, "is preparing the response...", 75}

  defp episode_status(%Episode{state: :working}),
    do: {:ok, :working, "is working...", 70}

  defp episode_status(%Episode{state: :waiting_for_input}),
    do: {:ok, :waiting_for_input, "is waiting for your answer...", 60}

  defp episode_status(%Episode{state: :waiting_for_event}),
    do: {:ok, :waiting_for_event, "is waiting for an external event...", 60}

  defp episode_status(%Episode{state: state}) when state in [:complete, :cancelled],
    do: {:ok, :clear, "", 20}

  defp episode_status(_episode), do: :ignore

  defp destination(
         %{
           destination_conversation_ref: conversation_ref,
           destination_thread_ref: thread_ref,
           destination_transport: "slack"
         },
         workspace_ref
       ) do
    case String.split(conversation_ref || "", ":", parts: 3) do
      ["slack", ^workspace_ref, channel_ref]
      when byte_size(channel_ref) > 0 and is_binary(thread_ref) and byte_size(thread_ref) > 0 ->
        if Regex.match?(~r/\A[A-Z0-9]+\z/, channel_ref) and
             Regex.match?(~r/\A[0-9]{10,}\.[0-9]{1,6}\z/, thread_ref) do
          {:ok, {channel_ref, thread_ref}}
        else
          :error
        end

      _invalid ->
        :error
    end
  end

  defp destination(_record, _workspace_ref), do: :error

  defp candidate({channel_ref, thread_ref} = key, phase, status, priority) do
    %{
      channel_ref: channel_ref,
      key: key,
      phase: phase,
      priority: priority,
      status: status,
      thread_ref: thread_ref
    }
  end
end
