defmodule Ryker.ControlPlane.IncidentProjection do
  @moduledoc """
  The incident-room directory and one room's detail: its lifecycle, the
  records its episode wrote (in their timeline cards' words) and its latest
  publication, with every room field selected explicitly and failure bodies
  projected through `FailureDetail`. A room's page redraws when the room or
  its investigation changes (`subscriptions/1`).
  """

  import Ecto.Query

  alias Ryker.ControlPlane.{Environments, RepositoryNames, Search}
  alias Ryker.Delivery.ChatCard
  alias Ryker.{Episodes, Settings}
  alias Ryker.Episodes.Episode
  alias Ryker.Operator.FailureDetail
  alias Ryker.Publication.Publication
  alias Ryker.Records.Record
  alias Ryker.Repo
  alias Ryker.Slack.{IncidentRoom, IncidentRoomLifecycleEvent, IncidentRooms}

  @list_limit 100
  @detail_limit 200
  @statuses ~w(requested ready blocked closed)a

  @doc """
  The topics a room's page listens to, as the context functions that
  subscribe to them (`Ryker.ControlPlane.WorkbenchLive`): the room, the
  investigation it runs once it has one (whose records and code change the
  page shows; the room is announced when it gets one), and the environments
  it names.
  """
  def subscriptions(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    investigation =
      case Repo.one(from(room in IncidentRoom, where: room.ref == ^ref, select: room.episode_id)) do
        nil -> []
        episode_id -> [{Episodes, :subscribe_episode, [episode_id]}]
      end

    [{IncidentRooms, :subscribe_room, [ref]}, {Settings, :subscribe, []}] ++ investigation
  end

  def subscriptions(_ref), do: []

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
          closing: not is_nil(room.close_requested_at) and room.status != :closed,
          episode_id: room.episode_id,
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

    rooms = Repo.all(query)
    names = if Enum.any?(rooms, & &1.repository_ref), do: RepositoryNames.all(), else: %{}

    Enum.map(
      rooms,
      &Map.put(&1, :repository_name, RepositoryNames.name(names, &1.repository_ref))
    )
  end

  def list(_params), do: list(%{})

  @doc """
  One incident room with its lifecycle, records and latest publication.

  The room carries its milestones as times (`channel_created_at`,
  `invited_at`, `ready_at`, `stopped_at`, `closed_at`), where its
  investigation stands (`episode_state`), the names of its environment and
  repository, and, for a room Ryker closed because Slack deleted its channel,
  the note it wrote about where its words went (`closed_note`). No other saved
  error leaves the Failures page.
  """
  def fetch(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    case Repo.one(from(room in IncidentRoom, where: room.ref == ^ref, limit: 1)) do
      nil ->
        :not_found

      room ->
        episode = if room.episode_id, do: Repo.get(Episode, room.episode_id)
        names = RepositoryNames.all()

        {:ok,
         %{
           lifecycle: lifecycle(room),
           publication: publication(room.episode_id, names),
           records: records(room.episode_id),
           room: room(room, episode, settings(), names)
         }}
    end
  end

  def fetch(_ref), do: :not_found

  defp room(room, episode, settings, names) do
    %{
      channel_created_at: channel_created_at(room),
      channel_name: room.channel_name,
      channel_ref: room.channel_ref,
      channel_state: room.channel_state,
      # A blocked room waits for a person and a closed one is final, so the
      # row's last change is when setup stopped or it closed.
      closed_at: if(room.status == :closed, do: room.updated_at),
      closed_note: closed_note(room),
      # A person asked to close it, and the room worker has not finished yet.
      closing: not is_nil(room.close_requested_at) and room.status != :closed,
      close_requested_at: room.close_requested_at,
      environment_name: environment_name(settings, room.environment_ref),
      environment_ref: room.environment_ref,
      episode_id: room.episode_id,
      episode_state: episode && episode.state,
      invited_at: room.audience_prepared_at,
      invited_groups: length(room.invite_user_group_refs),
      invited_people: length(room.invite_user_refs),
      private: room.private,
      # The investigation starts in the same transaction that makes the room
      # ready, so its request's creation is when it did.
      ready_at: episode && episode.inserted_at,
      record_ref:
        Repo.one(from(record in Record, where: record.id == ^room.record_id, select: record.ref)),
      ref: room.ref,
      repository_name: RepositoryNames.name(names, room.repository_ref),
      repository_ref: room.repository_ref,
      requested_at: room.requested_at,
      source_channel_ref: room.source_channel_ref,
      source_episode_id: room.source_episode_id,
      status: room.status,
      stopped_at: if(room.status == :blocked, do: room.updated_at),
      title: room.title,
      updated_at: room.updated_at,
      workspace_ref: room.workspace_ref
    }
  end

  defp lifecycle(room) do
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
  end

  # The newest records, oldest first: the page leads with the latest update,
  # which the oldest two hundred of a long investigation lack.
  defp records(nil), do: []

  defp records(episode_id) do
    Repo.all(
      from(record in Record,
        where: record.episode_id == ^episode_id,
        order_by: [desc: record.sequence, desc: record.id],
        limit: @detail_limit
      )
    )
    |> Enum.reverse()
    |> Enum.map(&record/1)
  end

  defp publication(nil, _names), do: nil

  defp publication(episode_id, names) do
    Repo.one(
      from(publication in Publication,
        where: publication.episode_id == ^episode_id,
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
    |> then(&(&1 && %{&1 | repository: RepositoryNames.name(names, &1.repository)}))
  end

  # Creating the channel is the first change of its state; every later one
  # (an archive, a deletion, a check that found it changed) names the event
  # that made it and overwrites the time, so only an unchanged channel still
  # knows when it was created.
  defp channel_created_at(%IncidentRoom{channel_ref: nil}), do: nil

  defp channel_created_at(%IncidentRoom{channel_state_event_ref: nil} = room),
    do: room.channel_state_changed_at

  defp channel_created_at(_room), do: nil

  # The worker writes this note, in fixed words, when it closes a room, on a
  # person's request or because Slack deleted its channel, for whoever opens
  # the room later: whether it said so in Slack and where a reply it still
  # owed waits.
  defp closed_note(%IncidentRoom{status: :closed, last_error_code: code} = room)
       when code in ["incident_room_closed", "incident_room_deleted"],
       do: room.last_error_detail

  defp closed_note(_room), do: nil

  defp settings do
    case Ryker.Settings.fetch() do
      {:ok, snapshot} -> snapshot
      {:error, :settings_not_initialized} -> nil
    end
  end

  # An environment removed since keeps the ref the room saved: history
  # outlives settings.
  defp environment_name(_settings, nil), do: nil
  defp environment_name(nil, ref), do: ref

  defp environment_name(settings, ref) do
    case Environments.find(settings, ref) do
      %{display_name: name} -> name
      nil -> ref
    end
  end

  # A record in the words its timeline card uses — "Evidence", the claim and
  # what was observed — beside its identity for support.
  defp record(%Record{} = record) do
    card =
      case ChatCard.project(record) do
        {:ok, card} -> card
        :ignore -> %{}
      end

    %{
      at: record.inserted_at,
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
