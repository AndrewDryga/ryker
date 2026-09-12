defmodule Responder.Slack.IncidentRoomCard do
  @moduledoc """
  Builds the host-owned projection for one pinned incident-room card.

  The projection is rebuilt from the episode and its typed records. It grants
  no authority and contains no model-created controls. Its fingerprint lets a
  worker retry an ambiguous Slack update against the same message.
  """

  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.Episodes.Episode
  alias Responder.Repo
  alias Responder.Slack.IncidentRoom
  alias Responder.State.{Record, Records}
  alias Responder.Work.{Session, Turn}

  @ui_revision 2
  @record_kinds ~w(alert_assessment event_wait input_request progress)
  @goals_shown 8

  @spec build(IncidentRoom.t()) ::
          {:ok, %{document: map(), fingerprint: String.t(), ui_revision: pos_integer()}}
          | {:error, term()}
  def build(%IncidentRoom{} = room) do
    with {:ok, projection} <- projection(room) do
      document = %{"incident_room" => projection}

      {:ok,
       %{
         document: document,
         fingerprint: CanonicalJSON.digest(document),
         ui_revision: @ui_revision
       }}
    end
  end

  def build(_room), do: {:error, :invalid_incident_room_card}

  defp projection(%IncidentRoom{episode_id: nil} = room) do
    {:ok,
     base(room)
     |> Map.merge(%{
       "action_needed" => nil,
       "alert" => nil,
       "controls" => [],
       "episode_state" => "provisioning",
       "goals" => [],
       "session_generation" => nil,
       "severity" => "not supplied",
       "signals" => %{"firing" => nil, "total" => nil},
       "status" => "provisioning",
       "summary" => compact(room.prompt, 500),
       "updated_at" => DateTime.to_iso8601(room.requested_at)
     })}
  end

  defp projection(%IncidentRoom{} = room) do
    case Repo.get(Episode, room.episode_id) do
      nil ->
        {:error, :incident_room_episode_not_found}

      %Episode{} = episode ->
        records = latest_records(episode.id)
        turn = current_turn(episode)
        session = latest_session(episode.id)

        {:ok,
         base(room)
         |> Map.merge(%{
           "action_needed" => action_needed(room, episode, records, turn),
           "alert" => alert(records),
           "controls" => controls(episode, turn, session),
           "episode_state" => Atom.to_string(episode.state),
           "goals" => goals(episode.id),
           "session_generation" => session && session.generation,
           "severity" => "not supplied",
           "signals" => %{"firing" => nil, "total" => nil},
           "status" => status(room, episode, turn),
           "summary" => summary(room, records),
           "updated_at" => DateTime.to_iso8601(episode.updated_at)
         })}
    end
  end

  defp base(room) do
    %{
      "opened_at" => DateTime.to_iso8601(room.requested_at),
      "opened_by" => room.requested_by_actor_ref,
      "repository" => room.repository_ref,
      "room_ref" => room.ref,
      "source" => %{
        "channel_ref" => room.source_channel_ref,
        "message_ref" => room.source_message_ref,
        "thread_ref" => room.source_thread_ref
      },
      "title" => room.title,
      "ui_revision" => @ui_revision
    }
  end

  # What the investigation set out to establish, and where each of those stands.
  # The task card has carried this ledger since 405e9443; an incident room, the
  # one surface where "what have we actually found" is the whole question, had
  # only a prose summary. The task's seven build stages are meaningless here, so
  # this is the goals themselves, bounded and in the order they were set. A goal
  # a later attempt superseded is not part of what the room is establishing now.
  defp goals(episode_id) do
    episode_id
    |> Records.goals()
    |> Enum.reject(& &1["successor_id"])
    |> Enum.take(@goals_shown)
    |> Enum.map(
      &%{
        "id" => &1["id"],
        "outcome" => compact(&1["requested_outcome"], 200),
        "state" => &1["state"]
      }
    )
  end

  defp latest_records(episode_id) do
    Repo.all(
      from(record in Record,
        where:
          record.episode_id == ^episode_id and record.kind in ^@record_kinds and
            record.status in [:open, :confirmed],
        order_by: [asc: record.sequence]
      )
    )
    |> Enum.reduce(%{}, &Map.put(&2, &1.kind, &1))
  end

  defp current_turn(%Episode{owner_kind: :turn, owner_ref: turn_ref} = episode) do
    Repo.get_by(Turn, episode_id: episode.id, turn_ref: turn_ref)
  end

  defp current_turn(%Episode{owner_kind: :delivery, owner_ref: delivery_ref} = episode) do
    Repo.get_by(Turn, episode_id: episode.id, delivery_ref: delivery_ref)
  end

  defp current_turn(episode) do
    Repo.one(
      from(turn in Turn,
        where: turn.episode_id == ^episode.id,
        order_by: [desc: turn.inserted_at, desc: turn.id],
        limit: 1
      )
    )
  end

  defp latest_session(episode_id) do
    Repo.one(
      from(session in Session,
        where: session.episode_id == ^episode_id,
        order_by: [desc: session.generation],
        limit: 1
      )
    )
  end

  defp status(%IncidentRoom{channel_state: state}, _episode, _turn) when state != :active,
    do: "paused"

  defp status(_room, %Episode{state: :cancelled}, _turn), do: "cancelled"
  defp status(_room, %Episode{state: :complete}, _turn), do: "resolved"
  defp status(_room, %Episode{state: :waiting_for_input}, _turn), do: "waiting_for_input"
  defp status(_room, %Episode{state: :waiting_for_event}, _turn), do: "waiting_for_event"
  defp status(_room, _episode, %Turn{status: :blocked}), do: "action_required"
  defp status(_room, _episode, %Turn{status: :cancel_pending}), do: "stopping"
  defp status(_room, _episode, _turn), do: "investigating"

  defp action_needed(%IncidentRoom{channel_state: :archived}, _episode, _records, _turn),
    do: "The Slack room is archived. Unarchive it to resume investigation and delivery."

  defp action_needed(%IncidentRoom{channel_state: :unavailable}, _episode, _records, _turn),
    do: "Slack no longer exposes this room. Restore access before work can resume."

  defp action_needed(%IncidentRoom{channel_state: :deleted}, _episode, _records, _turn),
    do: "Slack reports this room deleted. Its episode and audit history remain durable."

  defp action_needed(_room, %Episode{state: :waiting_for_input}, records, _turn) do
    case records["input_request"] do
      %Record{payload: %{"question" => question}} -> compact(question, 500)
      _missing -> "An operator response is required before the investigation can continue."
    end
  end

  defp action_needed(_room, %Episode{state: :waiting_for_event}, records, _turn) do
    case records["event_wait"] do
      %Record{payload: %{"verification" => verification}} -> compact(verification, 500)
      _missing -> "Responder is waiting for the configured verification event."
    end
  end

  defp action_needed(_room, _episode, _records, %Turn{status: :blocked} = turn) do
    compact(turn.last_error_detail || "Work is blocked and needs operator attention.", 500)
  end

  defp action_needed(_room, _episode, _records, _turn), do: nil

  defp alert(records) do
    case records["alert_assessment"] do
      %Record{payload: payload} ->
        %{
          "impact" => compact(payload["impact"], 500),
          "verdict" => payload["verdict"]
        }

      _missing ->
        nil
    end
  end

  defp summary(room, records) do
    cond do
      match?(%Record{}, records["progress"]) ->
        compact(records["progress"].payload["summary"], 500)

      match?(%Record{}, records["alert_assessment"]) ->
        compact(records["alert_assessment"].payload["impact"], 500)

      true ->
        compact(room.prompt, 500)
    end
  end

  defp controls(episode, turn, session) do
    []
    |> maybe_control(stop_allowed?(episode, turn), "stop")
    |> maybe_control(bound_session?(session), "view_diff")
    |> maybe_control(close_allowed?(episode, turn), "close")
    |> Kernel.++(~w(timeline evidence handoff postmortem))
  end

  defp stop_allowed?(%Episode{state: :working, owner_kind: :turn, owner_ref: turn_ref}, %Turn{
         status: :pending,
         turn_ref: turn_ref
       }),
       do: true

  defp stop_allowed?(_episode, _turn), do: false

  defp close_allowed?(%Episode{state: state}, _turn) when state in [:complete, :cancelled],
    do: false

  defp close_allowed?(_episode, %Turn{status: status})
       when status in [:cancel_pending, :delivery_pending],
       do: false

  defp close_allowed?(_episode, _turn), do: true

  defp bound_session?(%Session{coop_session_id: value}) when is_binary(value) and value != "",
    do: true

  defp bound_session?(_session), do: false

  defp maybe_control(controls, true, control), do: controls ++ [control]
  defp maybe_control(controls, false, _control), do: controls

  defp compact(value, maximum) when is_binary(value), do: String.slice(value, 0, maximum)
  defp compact(_value, _maximum), do: nil
end
