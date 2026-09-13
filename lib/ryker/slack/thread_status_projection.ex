defmodule Ryker.Slack.ThreadStatusProjection do
  @moduledoc """
  Projects durable ingress and episode ownership onto Slack assistant threads.

  The database remains authoritative. Recent terminal rows are included so a
  restarted worker can clear a status that Slack still displays.
  """

  import Ecto.Query

  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry
  alias Ryker.Repo
  alias Ryker.Work.Turn

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
    episodes = recent_episodes(workspace_ref, cutoff)

    {:ok,
     targets(
       recent_entries(workspace_ref, cutoff),
       episodes,
       parked_owners(episodes),
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

  # Blocking a turn does not transition its episode, so a parked task is still a
  # `:working` row owned by a turn that stopped. Without this the thread keeps
  # refreshing "is working..." every 90 seconds for work nobody is doing.
  defp parked_owners(episodes) do
    owners =
      for %Episode{id: id, owner_kind: :turn, owner_ref: ref} <- episodes,
          is_binary(ref),
          do: {id, ref}

    if owners == [] do
      MapSet.new()
    else
      {episode_ids, turn_refs} = Enum.unzip(owners)

      from(turn in Turn,
        where:
          turn.episode_id in ^episode_ids and turn.turn_ref in ^turn_refs and
            turn.status == :blocked,
        select: {turn.episode_id, turn.turn_ref}
      )
      |> Repo.all()
      |> MapSet.new()
    end
  end

  @doc false
  @spec targets([Entry.t()], [Episode.t()], MapSet.t(), String.t()) :: [map()]
  def targets(entries, episodes, parked, workspace_ref)
      when is_list(entries) and is_list(episodes) and is_binary(workspace_ref) do
    (Enum.flat_map(entries, &entry_candidate(&1, workspace_ref)) ++
       Enum.flat_map(episodes, &episode_candidate(&1, parked, workspace_ref)))
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

  defp episode_candidate(%Episode{execution_mode: :live} = episode, parked, workspace_ref) do
    with {:ok, key} <- destination(episode, workspace_ref),
         {:ok, phase, status, priority} <- episode_status(episode, parked) do
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

  defp episode_candidate(_episode, _parked, _workspace_ref), do: []

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

  defp episode_status(%Episode{state: :working, owner_kind: :delivery}, _parked),
    do: {:ok, :delivery, "is preparing the response...", 75}

  # Below every entry phase, so a new message on the same thread still reports
  # itself rather than being silenced by the parked task it arrived beside.
  defp episode_status(%Episode{state: :working, owner_kind: :turn} = episode, parked) do
    if MapSet.member?(parked, {episode.id, episode.owner_ref}),
      do: {:ok, :blocked, "", 65},
      else: {:ok, :working, "is working...", 70}
  end

  defp episode_status(%Episode{state: :working}, _parked),
    do: {:ok, :working, "is working...", 70}

  defp episode_status(%Episode{state: :waiting_for_input}, _parked),
    do: {:ok, :waiting_for_input, "", 60}

  defp episode_status(%Episode{state: :waiting_for_event}, _parked),
    do: {:ok, :waiting_for_event, "", 60}

  defp episode_status(%Episode{state: state}, _parked) when state in [:complete, :cancelled],
    do: {:ok, :clear, "", 20}

  defp episode_status(_episode, _parked), do: :ignore

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
