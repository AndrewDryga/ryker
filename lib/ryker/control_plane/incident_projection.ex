defmodule Ryker.ControlPlane.IncidentProjection do
  @moduledoc """
  The incident-room directory and one room's detail: its lifecycle, the
  records its episode wrote (in their timeline cards' words) and its latest
  publication, with every room field selected explicitly and failure bodies
  projected through `FailureDetail`.
  """

  import Ecto.Query

  alias Ryker.ControlPlane.{Card, EpisodeProjection, Search}
  alias Ryker.Episodes.Episode
  alias Ryker.Operator.FailureDetail
  alias Ryker.Publication.Publication
  alias Ryker.Repo
  alias Ryker.Slack.{IncidentRoom, IncidentRoomLifecycleEvent}
  alias Ryker.State.Record

  @list_limit 100
  @detail_limit 200
  @statuses ~w(requested ready blocked closed)a

  @doc "The incident-room directory, filtered by status and search."
  def list(params) when is_map(params) do
    latest_publications =
      from(publication in Publication,
        distinct: publication.episode_id,
        order_by: [
          asc: publication.episode_id,
          desc: publication.updated_at,
          desc: publication.id
        ],
        select: %{
          episode_id: publication.episode_id,
          ref: publication.ref,
          status: publication.status
        }
      )

    query =
      from(room in IncidentRoom,
        left_join: episode in Episode,
        on: episode.id == room.episode_id,
        left_join: publication in subquery(latest_publications),
        on: publication.episode_id == room.episode_id,
        # Newest opened first: the page heads each day with when rooms opened.
        order_by: [desc_nulls_last: room.requested_at, desc: room.updated_at, desc: room.id],
        limit: @list_limit,
        select: %{
          channel_name: room.channel_name,
          channel_ref: room.channel_ref,
          channel_state: room.channel_state,
          episode_ref: episode.key,
          private: room.private,
          publication_ref: publication.ref,
          publication_status: publication.status,
          ref: room.ref,
          repository_ref: room.repository_ref,
          requested_at: room.requested_at,
          status: room.status,
          title: room.title,
          updated_at: room.updated_at,
          workspace_ref: room.workspace_ref
        }
      )
      |> incident_status(Search.one_of(params["status"], @statuses))
      |> incident_search(Search.term(params["q"]))

    Repo.all(query)
  end

  def list(_params), do: list(%{})

  @doc "One incident room with its lifecycle, records and latest publication."
  def fetch(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case Repo.one(from(room in IncidentRoom, where: room.ref == ^ref, limit: 1)) do
      nil ->
        :not_found

      room ->
        episode = if room.episode_id, do: Repo.get(Episode, room.episode_id)

        lifecycle =
          Repo.all(
            from(event in IncidentRoomLifecycleEvent,
              where: event.room_id == ^room.id,
              order_by: [asc: event.occurred_at, asc: event.id],
              limit: @detail_limit,
              select: %{
                kind: event.kind,
                occurred_at: event.occurred_at,
                channel_ref: event.channel_ref
              }
            )
          )

        records =
          if room.episode_id do
            Repo.all(
              from(record in Record,
                where: record.episode_id == ^room.episode_id,
                order_by: [asc: record.sequence, asc: record.id],
                limit: @detail_limit
              )
            )
            |> Enum.map(&record/1)
          else
            []
          end

        publication =
          if room.episode_id do
            Repo.one(
              from(publication in Publication,
                where: publication.episode_id == ^room.episode_id,
                order_by: [desc: publication.updated_at, desc: publication.id],
                limit: 1,
                select: %{
                  branch_ref: publication.branch_ref,
                  commit_sha: publication.commit_sha,
                  last_error: publication.last_error_detail,
                  pr_number: publication.pull_request_number,
                  pr_url: publication.pull_request_url,
                  ref: publication.ref,
                  repository: publication.repository,
                  status: publication.status,
                  updated_at: publication.updated_at
                }
              )
            )
            |> sanitize_publication()
          end

        {:ok,
         %{
           lifecycle: lifecycle,
           publication: publication,
           records: records,
           room: %{
             channel_name: room.channel_name,
             channel_ref: room.channel_ref,
             channel_state: room.channel_state,
             episode_ref: episode && episode.key,
             private: room.private,
             ref: room.ref,
             repository_ref: room.repository_ref,
             requested_at: room.requested_at,
             source_channel_ref: room.source_channel_ref,
             source_episode_ref: EpisodeProjection.key(room.source_episode_id),
             status: room.status,
             title: room.title,
             updated_at: room.updated_at,
             workspace_ref: room.workspace_ref
           }
         }}
    end
  end

  def fetch(_ref), do: :not_found

  # A record in the words its timeline card uses — "Evidence", the claim and
  # what was observed — beside its identity for support.
  defp record(%Record{} = record) do
    card =
      case Card.project(record) do
        {:ok, card} -> card
        :ignore -> %{}
      end

    %{
      kind: record.kind,
      label: card[:label],
      ref: record.ref,
      status: record.status,
      subject: record.subject_ref,
      summary: card[:summary],
      title: card[:title]
    }
  end

  defp incident_status(query, nil), do: query

  defp incident_status(query, status),
    do: from([room, _, _] in query, where: room.status == ^status)

  defp incident_search(query, nil), do: query

  defp incident_search(query, search) do
    pattern = Search.contains(search)

    from([room, _, _] in query,
      where:
        ilike(room.ref, ^pattern) or ilike(room.title, ^pattern) or
          ilike(room.repository_ref, ^pattern) or ilike(room.workspace_ref, ^pattern) or
          ilike(room.source_channel_ref, ^pattern) or ilike(room.channel_ref, ^pattern)
    )
  end

  defp sanitize_publication(nil), do: nil

  defp sanitize_publication(publication) do
    Map.put(publication, :last_error, FailureDetail.project(publication.last_error))
  end
end
