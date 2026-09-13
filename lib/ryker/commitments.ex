defmodule Ryker.Commitments do
  @moduledoc """
  A read-only projection of episode-owned commitments.

  It deliberately owns no lifecycle row. Episode, Work, and typed state records
  remain authoritative; this projection gives conversations and control planes
  one bounded account of what Ryker owes next.
  """

  import Ecto.Query

  alias Ryker.Episodes.Episode
  alias Ryker.Repo
  alias Ryker.State.Record
  alias Ryker.Work.Turn

  @maximum 100
  @default_limit 25

  @spec list_for_token(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_for_token(token, options \\ [])

  def list_for_token("state:" <> turn_id, options) do
    with {:ok, turn_id} <- Ecto.UUID.cast(turn_id),
         {:ok, limit} <- limit(options),
         {:ok, episode} <- authorized_episode(turn_id) do
      {:ok, list_destination(episode, limit)}
    else
      _invalid -> {:error, :commitment_unauthorized}
    end
  end

  def list_for_token(_token, _options), do: {:error, :commitment_unauthorized}

  @spec list_destination(Episode.t(), pos_integer()) :: [map()]
  def list_destination(source, limit \\ @default_limit)

  def list_destination(%Episode{} = source, limit)
      when is_integer(limit) and limit in 1..@maximum do
    episodes =
      Repo.all(
        from(episode in Episode,
          where:
            episode.destination_transport == ^source.destination_transport and
              episode.destination_conversation_ref == ^source.destination_conversation_ref and
              episode.state != :complete,
          order_by: [desc: episode.updated_at, desc: episode.id],
          limit: ^limit
        )
      )

    project(episodes, database_now!())
  end

  def list_destination(_source, _limit), do: []

  defp authorized_episode(turn_id) do
    case Repo.one(
           from(turn in Turn,
             join: episode in Episode,
             on: episode.id == turn.episode_id,
             where:
               turn.id == ^turn_id and turn.status == :pending and
                 episode.state == :working and episode.owner_kind == :turn and
                 episode.owner_ref == turn.turn_ref,
             select: episode
           )
         ) do
      nil -> {:error, :commitment_unauthorized}
      episode -> {:ok, episode}
    end
  end

  defp project([], _now), do: []

  defp project(episodes, now) do
    ids = Enum.map(episodes, & &1.id)

    turns =
      Repo.all(from(turn in Turn, where: turn.episode_id in ^ids))
      |> Map.new(&{{&1.episode_id, &1.turn_ref}, &1})

    records =
      Repo.all(
        from(record in Record,
          where:
            record.episode_id in ^ids and
              record.kind in ["goal", "goal_state", "progress"],
          order_by: [asc: record.sequence]
        )
      )
      |> Enum.group_by(& &1.episode_id)

    Enum.map(episodes, fn episode ->
      episode_records = Map.get(records, episode.id, [])
      turn = Map.get(turns, {episode.id, episode.owner_ref})
      progress = latest_record(episode_records, "progress")

      %{
        "destination" => %{
          "conversation_ref" => episode.destination_conversation_ref,
          "thread_ref" => episode.destination_thread_ref,
          "transport" => episode.destination_transport
        },
        "episode_ref" => episode.key,
        "latest_progress" => progress && progress.payload,
        "next_action" => next_action(episode, turn),
        "overdue" => overdue?(episode, progress, now),
        "required_goals" => required_goals(episode_records),
        "state" => Atom.to_string(episode.state),
        "status" => status(episode, turn),
        "updated_at" => DateTime.to_iso8601(episode.updated_at)
      }
    end)
  end

  defp latest_record(records, kind) do
    records
    |> Enum.filter(&(&1.kind == kind))
    |> List.last()
  end

  defp required_goals(records) do
    goals =
      records
      |> Enum.filter(&(&1.kind == "goal" and &1.payload["required"] == true))
      |> Map.new(&{&1.payload["id"], &1.payload})

    states =
      records
      |> Enum.filter(&(&1.kind == "goal_state"))
      |> Map.new(&{&1.payload["goal_id"], &1.payload["state"]})

    goals
    |> Enum.map(fn {id, goal} ->
      %{
        "id" => id,
        "requested_outcome" => goal["requested_outcome"],
        "state" => Map.get(states, id, "ready")
      }
    end)
    |> Enum.reject(&(&1["state"] in ~w(completed excluded cancelled)))
    |> Enum.sort_by(& &1["id"])
  end

  defp status(%Episode{state: :cancelled}, _turn), do: "cancelled"
  defp status(%Episode{state: :waiting_for_input}, _turn), do: "blocked"
  defp status(%Episode{state: :waiting_for_event}, _turn), do: "waiting"
  defp status(%Episode{owner_kind: :delivery}, _turn), do: "finishing"
  defp status(_episode, %Turn{status: :blocked}), do: "blocked"
  defp status(_episode, %Turn{status: :cancel_pending}), do: "finishing"

  defp status(_episode, %Turn{coop_turn_id: nil, lease_ref: nil, status: :pending}),
    do: "queued"

  defp status(_episode, %Turn{status: :pending}), do: "working"
  defp status(_episode, _turn), do: "working"

  defp next_action(%Episode{state: :waiting_for_input}, _turn), do: "operator_input"
  defp next_action(%Episode{state: :waiting_for_event}, _turn), do: "external_event"
  defp next_action(%Episode{owner_kind: :delivery}, _turn), do: "deliver_result"
  defp next_action(_episode, %Turn{status: :blocked}), do: "operator_recovery"
  defp next_action(_episode, %Turn{status: :cancel_pending}), do: "reconcile_stop"
  defp next_action(_episode, %Turn{coop_turn_id: nil}), do: "start_work"
  defp next_action(_episode, _turn), do: "continue_work"

  defp overdue?(episode, progress, now) do
    deadline_overdue?(episode.owner_deadline_at, now) or
      progress_overdue?(progress && progress.payload["next_due_at"], now)
  end

  defp deadline_overdue?(nil, _now), do: false

  defp deadline_overdue?(%DateTime{} = deadline, now),
    do: DateTime.compare(deadline, now) != :gt

  defp progress_overdue?(nil, _now), do: false

  defp progress_overdue?(value, now) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, due_at, 0} -> DateTime.compare(due_at, now) != :gt
      _invalid -> false
    end
  end

  defp progress_overdue?(_value, _now), do: false

  defp limit(options) when is_list(options) do
    value = Keyword.get(options, :limit, @default_limit)

    if Keyword.keyword?(options) and Keyword.keys(options) -- [:limit] == [] and
         is_integer(value) and value in 1..@maximum,
       do: {:ok, value},
       else: {:error, :commitment_unauthorized}
  end

  defp limit(_options), do: {:error, :commitment_unauthorized}

  defp database_now! do
    {:ok, %{rows: [[%DateTime{} = now]]}} = Repo.query("SELECT clock_timestamp()")
    now
  end
end
