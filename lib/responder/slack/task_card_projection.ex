defmodule Responder.Slack.TaskCardProjection do
  @moduledoc """
  Builds one bounded, host-owned engineering-task card from canonical state.
  """

  import Ecto.Query

  alias Responder.CanonicalJSON
  alias Responder.Episodes.Episode
  alias Responder.Publication.Publication
  alias Responder.Repo
  alias Responder.Slack.TaskCard
  alias Responder.State.{Record, Records}
  alias Responder.Work.{Session, Turn}

  @ui_revision 3

  @spec build(TaskCard.t()) ::
          {:ok, %{document: map(), fingerprint: String.t(), ui_revision: pos_integer()}}
          | {:error, term()}
  def build(%TaskCard{} = card) do
    with %Record{} = record <- Repo.get(Record, card.record_id),
         %Episode{} = episode <- Repo.get(Episode, card.episode_id) do
      project(record, episode, card.ref)
    else
      nil -> {:error, :task_card_source_not_found}
    end
  end

  @doc false
  @spec build(Record.t()) ::
          {:ok, %{document: map(), fingerprint: String.t(), ui_revision: pos_integer()}}
          | {:error, term()}
  def build(
        %Record{
          kind: "task_offer",
          status: :confirmed,
          confirmed_episode_id: episode_id
        } = record
      )
      when is_binary(episode_id) do
    case Repo.get(Episode, episode_id) do
      %Episode{} = episode -> project(record, episode, record.ref)
      nil -> {:error, :task_card_source_not_found}
    end
  end

  def build(_card), do: {:error, :invalid_task_card}

  defp project(record, episode, task_ref) do
    turn = current_turn(episode)
    session = latest_session(episode.id)
    publication = latest_publication(episode.id)
    records = Records.model_records(episode.id)
    publication_offer = latest_publication_offer(episode.id)

    projection = %{
      "action_needed" => action_needed(episode, turn, records, publication),
      "confirmed_at" => DateTime.to_iso8601(record.confirmed_at),
      "confirmed_by" => record.confirmed_by_actor_ref,
      "controls" => controls(record, episode, turn, session, publication),
      "episode_state" => Atom.to_string(episode.state),
      "publication" => publication(publication, publication_offer),
      "repository" => record.payload["repository"],
      "session_generation" => session && session.generation,
      "status" => status(episode, turn, publication, publication_offer),
      "summary" => summary(record, records),
      "task_ref" => task_ref,
      "title" => record.payload["title"],
      "ui_revision" => @ui_revision,
      "updated_at" => DateTime.to_iso8601(episode.updated_at),
      "work_state" => turn && Atom.to_string(turn.status)
    }

    document = %{"task_card" => projection}

    {:ok,
     %{
       document: document,
       fingerprint: CanonicalJSON.digest(document),
       publication_offer_ref: publication_offer && publication_offer["ref"],
       ui_revision: @ui_revision
     }}
  end

  defp current_turn(%Episode{owner_kind: :turn, owner_ref: turn_ref} = episode),
    do: Repo.get_by(Turn, episode_id: episode.id, turn_ref: turn_ref)

  defp current_turn(%Episode{owner_kind: :delivery, owner_ref: delivery_ref} = episode),
    do: Repo.get_by(Turn, episode_id: episode.id, delivery_ref: delivery_ref)

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

  defp latest_publication(episode_id) do
    Repo.one(
      from(publication in Publication,
        where: publication.episode_id == ^episode_id,
        order_by: [desc: publication.inserted_at, desc: publication.id],
        limit: 1
      )
    )
  end

  defp status(_episode, _turn, %Publication{status: :published}, _offer), do: "published"

  defp status(_episode, _turn, %Publication{status: status}, _offer)
       when status in [:review_pending, :review_ready, :publish_pending, :published_ready],
       do: "reviewing"

  defp status(_episode, _turn, %Publication{status: :reviewed}, _offer),
    do: "ready_to_publish"

  defp status(_episode, _turn, %Publication{status: :blocked}, _offer),
    do: "action_required"

  defp status(%Episode{state: :cancelled}, _turn, _publication, _offer), do: "cancelled"
  defp status(_episode, _turn, nil, %{"status" => "open"}), do: "ready_for_review"
  defp status(%Episode{state: :complete}, _turn, _publication, _offer), do: "completed"

  defp status(%Episode{state: :waiting_for_input}, _turn, _publication, _offer),
    do: "waiting_for_input"

  defp status(%Episode{state: :waiting_for_event}, _turn, _publication, _offer),
    do: "waiting_for_event"

  defp status(_episode, %Turn{status: :blocked}, _publication, _offer),
    do: "action_required"

  defp status(_episode, %Turn{status: :cancel_pending}, _publication, _offer), do: "stopping"
  defp status(_episode, _turn, _publication, _offer), do: "working"

  defp action_needed(_episode, _turn, _records, %Publication{status: :blocked} = publication),
    do:
      compact(
        publication.last_error_detail || "Draft pull-request work needs operator attention.",
        500
      )

  defp action_needed(%Episode{state: :waiting_for_input}, _turn, records, _publication),
    do: wait_summary(records, "input_request", "An operator response is required.")

  defp action_needed(%Episode{state: :waiting_for_event}, _turn, records, _publication),
    do: wait_summary(records, "event_wait", "The task is waiting for external verification.")

  defp action_needed(_episode, %Turn{status: :blocked} = turn, _records, _publication),
    do:
      compact(turn.last_error_detail || "Task work is blocked and needs operator attention.", 500)

  defp action_needed(_episode, _turn, _records, _publication), do: nil

  defp wait_summary(records, kind, fallback) do
    records
    |> Enum.reverse()
    |> Enum.find(&(&1["kind"] == kind))
    |> case do
      %{"payload" => %{"question" => question}} -> compact(question, 500)
      %{"payload" => %{"verification" => verification}} -> compact(verification, 500)
      _missing -> fallback
    end
  end

  defp summary(record, records) do
    records
    |> Enum.reverse()
    |> Enum.find(&(&1["kind"] == "progress"))
    |> case do
      %{"payload" => %{"summary" => summary}} -> compact(summary, 500)
      _missing -> compact(record.payload["prompt"], 500)
    end
  end

  defp publication(nil, nil), do: nil

  defp publication(nil, %{"ref" => ref}) do
    %{
      "controls" => ["readiness"],
      "publication_ref" => nil,
      "pull_request_number" => nil,
      "pull_request_url" => nil,
      "review_offer_ref" => ref,
      "status" => "offered"
    }
  end

  defp publication(%Publication{} = publication, _offer) do
    %{
      "controls" => publication_controls(publication),
      "publication_ref" => publication.ref,
      "pull_request_number" => publication.pull_request_number,
      "pull_request_url" => publication.pull_request_url,
      "review_offer_ref" => nil,
      "status" => Atom.to_string(publication.status)
    }
  end

  defp publication_controls(%Publication{status: :reviewed}), do: ["publish"]
  defp publication_controls(%Publication{status: :published}), do: ["open", "check"]
  defp publication_controls(%Publication{status: :published_ready}), do: ["open"]
  defp publication_controls(_publication), do: []

  defp latest_publication_offer(episode_id) do
    Repo.all(
      from(record in Responder.State.Record,
        join: turn in Turn,
        on: turn.id == record.turn_id and turn.episode_id == record.episode_id,
        where:
          record.episode_id == ^episode_id and record.kind == "publication_offer" and
            record.status == :open and turn.status == :settled,
        order_by: [desc: record.sequence],
        limit: 16,
        select: {record, turn.delivery_document}
      )
    )
    |> Enum.find_value(fn {record, delivery_document} ->
      record_refs = get_in(delivery_document || %{}, ["outcome", "record_refs"])

      if host_publication_offer?(record) or
           (is_list(record_refs) and record.ref in record_refs),
         do: %{
           "kind" => record.kind,
           "payload" => record.payload,
           "ref" => record.ref,
           "status" => Atom.to_string(record.status)
         }
    end)
  end

  defp host_publication_offer?(%{operation_id: "host:publication:ready"}), do: true
  defp host_publication_offer?(_record), do: false

  defp controls(record, episode, turn, session, publication) do
    []
    |> maybe_control(stop_allowed?(episode, turn), "stop")
    |> maybe_control(bound_session?(session), "view_diff")
    |> maybe_control(close_allowed?(episode, turn, publication), "close")
    |> Kernel.++(~w(timeline evidence handoff))
    |> maybe_control(incident?(record), "postmortem")
  end

  defp incident?(%Record{payload: %{"kind" => "incident"}}), do: true
  defp incident?(_record), do: false

  defp stop_allowed?(%Episode{state: :working, owner_kind: :turn, owner_ref: turn_ref}, %Turn{
         status: :pending,
         turn_ref: turn_ref
       }),
       do: true

  defp stop_allowed?(_episode, _turn), do: false

  defp close_allowed?(%Episode{state: state}, _turn, _publication)
       when state in [:complete, :cancelled],
       do: false

  defp close_allowed?(_episode, %Turn{status: status}, _publication)
       when status in [:cancel_pending, :delivery_pending],
       do: false

  defp close_allowed?(_episode, _turn, %Publication{status: status})
       when status in [:review_pending, :review_ready, :publish_pending, :published_ready],
       do: false

  defp close_allowed?(_episode, _turn, _publication), do: true

  defp bound_session?(%Session{coop_session_id: value}) when is_binary(value) and value != "",
    do: true

  defp bound_session?(_session), do: false

  defp maybe_control(controls, true, control), do: controls ++ [control]
  defp maybe_control(controls, false, _control), do: controls

  defp compact(value, maximum) when is_binary(value), do: String.slice(value, 0, maximum)
  defp compact(_value, _maximum), do: nil
end
