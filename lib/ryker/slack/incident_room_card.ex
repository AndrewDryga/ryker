defmodule Ryker.Slack.IncidentRoomCard do
  @moduledoc """
  Builds the host-owned projection for one pinned incident-room card.

  The projection is rebuilt from the episode and its typed records. It grants
  no authority and contains no model-created controls. Its fingerprint lets a
  worker retry an ambiguous Slack update against the same message.
  """
  alias Ryker.CanonicalJSON
  alias Ryker.Episodes
  alias Ryker.Records
  alias Ryker.Repo
  alias Ryker.Slack.IncidentRoom
  alias Ryker.Slack.Renderer.Fields
  alias Ryker.Slack.WorkControls
  alias Ryker.Work

  # 3 since 2026-10-06: the card reads in words, without Ryker's ids and codes.
  @ui_revision 3
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
       "goals" => [],
       "status" => "provisioning",
       "summary" => Fields.cut(room.prompt, 500),
       "updated_at" => DateTime.to_iso8601(room.requested_at)
     })}
  end

  defp projection(%IncidentRoom{} = room) do
    case Repo.fetch(Episodes.Episode.Query.by_id(room.episode_id)) do
      {:error, :not_found} ->
        {:error, :incident_room_episode_not_found}

      {:ok, %Episodes.Episode{} = episode} ->
        records = latest_records(episode.id)
        turn = Repo.peek(Work.Turn.Query.current(episode))
        session = Repo.peek(Work.Session.Query.latest_of_episode(episode.id))

        {:ok,
         base(room)
         |> Map.merge(%{
           "action_needed" => action_needed(room, episode, records, turn),
           "alert" => alert(records),
           "controls" => controls(episode, turn, session),
           "goals" => goals(episode.id),
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
      "source_channel_ref" => room.source_channel_ref,
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
        "detail" => Fields.cut(&1["detail"], 200),
        "id" => &1["id"],
        "outcome" => Fields.cut(&1["requested_outcome"], 200),
        "state" => &1["state"]
      }
    )
  end

  defp latest_records(episode_id) do
    episode_id
    |> Records.Record.Query.by_episode_id()
    |> Records.Record.Query.by_kinds(@record_kinds)
    |> Records.Record.Query.in_use()
    |> Records.Record.Query.ordered_by_sequence()
    |> Repo.all()
    |> Enum.reduce(%{}, &Map.put(&2, &1.kind, &1))
  end

  defp status(%IncidentRoom{channel_state: state}, _episode, _turn) when state != :active,
    do: "paused"

  defp status(_room, %Episodes.Episode{state: :cancelled}, _turn), do: "cancelled"
  defp status(_room, %Episodes.Episode{state: :complete}, _turn), do: "resolved"
  defp status(_room, %Episodes.Episode{state: :waiting_for_input}, _turn), do: "waiting_for_input"
  defp status(_room, %Episodes.Episode{state: :waiting_for_event}, _turn), do: "waiting_for_event"
  defp status(_room, _episode, %Work.Turn{status: :blocked}), do: "action_required"
  defp status(_room, _episode, %Work.Turn{status: :cancel_pending}), do: "stopping"
  defp status(_room, _episode, _turn), do: "investigating"

  defp action_needed(%IncidentRoom{channel_state: :archived}, _episode, _records, _turn),
    do: "The Slack room is archived. Unarchive it to resume investigation and delivery."

  defp action_needed(%IncidentRoom{channel_state: :unavailable}, _episode, _records, _turn),
    do: "Slack no longer exposes this room. Restore access before work can resume."

  defp action_needed(%IncidentRoom{channel_state: :deleted}, _episode, _records, _turn),
    do: "Slack says this room was deleted. Ryker keeps its investigation and history."

  defp action_needed(_room, %Episodes.Episode{state: :waiting_for_input}, records, _turn) do
    case records["input_request"] do
      %Records.Record{payload: %{"question" => question}} -> Fields.cut(question, 500)
      _missing -> "An operator response is required before the investigation can continue."
    end
  end

  defp action_needed(_room, %Episodes.Episode{state: :waiting_for_event}, records, _turn) do
    case records["event_wait"] do
      %Records.Record{payload: %{"verification" => verification}} -> Fields.cut(verification, 500)
      _missing -> "Ryker is waiting for the configured verification event."
    end
  end

  # The saved error is Ryker's record of it, a code and whatever the worker
  # said; the pinned card printed it whole in the room everyone reads
  # (2026-10-04 review). It says in words what Ryker can tell of it, as a task
  # card does, and otherwise where the cause is written.
  defp action_needed(_room, _episode, _records, %Work.Turn{status: :blocked} = turn) do
    turn
    |> Work.FailureCause.summary(
      "The investigation stopped and needs a person. The cause is on Ryker's Failures page."
    )
    |> Fields.cut(500)
  end

  defp action_needed(_room, _episode, _records, _turn), do: nil

  defp alert(records) do
    case records["alert_assessment"] do
      %Records.Record{payload: payload} ->
        %{
          "impact" => Fields.cut(payload["impact"], 500),
          "verdict" => payload["verdict"]
        }

      _missing ->
        nil
    end
  end

  defp summary(room, records) do
    cond do
      match?(%Records.Record{}, records["progress"]) ->
        Fields.cut(records["progress"].payload["summary"], 500)

      match?(%Records.Record{}, records["alert_assessment"]) ->
        Fields.cut(records["alert_assessment"].payload["impact"], 500)

      true ->
        Fields.cut(room.prompt, 500)
    end
  end

  defp controls(episode, turn, session) do
    shown = [
      {WorkControls.stoppable?(episode, turn), "stop"},
      {WorkControls.diff_available?(session), "view_diff"},
      {close_allowed?(episode, turn), "close"},
      {true, "timeline"},
      {true, "evidence"},
      {true, "handoff"},
      {true, "postmortem"}
    ]

    for {true, control} <- shown, do: control
  end

  defp close_allowed?(%Episodes.Episode{state: state}, _turn)
       when state in [:complete, :cancelled],
       do: false

  defp close_allowed?(_episode, %Work.Turn{status: status})
       when status in [:cancel_pending, :delivery_pending],
       do: false

  defp close_allowed?(_episode, _turn), do: true
end
