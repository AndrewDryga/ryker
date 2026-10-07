defmodule Ryker.ControlPlane.IncidentProjection do
  @moduledoc """
  The incident-room directory and one room's detail: its lifecycle, the
  records its episode wrote (in their timeline cards' words) and its latest
  publication, with every room field selected explicitly and failure bodies
  projected through `FailureDetail`. A room's page redraws when the room or
  its investigation changes (`subscriptions/1`).
  """

  alias Ryker.Accounting.Execution
  alias Ryker.ControlPlane.{ConsolePeople, Environments, IncidentReport, PagedRelation}
  alias Ryker.ControlPlane.{RepositoryNames, Search, UsageProjection}
  alias Ryker.Delivery.ChatCard
  alias Ryker.{Episodes, InspectionRedactor, Settings}
  alias Ryker.Episodes.Episode
  alias Ryker.Operator.FailureDetail
  alias Ryker.Records.Record
  alias Ryker.Repo
  alias Ryker.Slack.{IncidentRoom, IncidentRoomLifecycleEvent}
  alias Ryker.Slack.{IncidentRooms, Names}

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
    episode_id =
      ref |> IncidentRoom.Query.by_ref() |> IncidentRoom.Query.select_episode_ids() |> Repo.one()

    investigation = if episode_id, do: [{Episodes, :subscribe_episode, [episode_id]}], else: []

    [{IncidentRooms, :subscribe_room, [ref]}, {Settings, :subscribe, []}] ++ investigation
  end

  def subscriptions(_ref), do: []

  @doc """
  One page of the incident-room directory under `params["page"]`, filtered by
  status and search, newest opened first, with how many rooms match (`total`)
  and how many of the rooms the search matches are open (`open`).

  The directory stopped at 100 rooms and counted only those (2026-10-04
  review).
  """
  def list(params) when is_map(params) do
    searched = incident_search(IncidentRoom.Query.all(), Search.term(params["q"]))
    filtered = incident_status(searched, Search.one_of(params["status"], @statuses))

    page =
      filtered
      |> IncidentReport.Query.directory()
      # Newest opened first: the page heads each day with when rooms opened.
      |> PagedRelation.read(
        [desc_nulls_last: :requested_at, desc: :updated_at, desc: :id],
        "page",
        params
      )

    names = if Enum.any?(page.items, & &1.repository_ref), do: RepositoryNames.all(), else: %{}

    page
    |> Map.put(
      :items,
      Enum.map(
        page.items,
        &Map.put(&1, :repository_name, RepositoryNames.name(names, &1.repository_ref))
      )
    )
    |> Map.put(
      :open,
      searched |> IncidentReport.Query.by_status(:ready) |> Repo.aggregate(:count)
    )
  end

  def list(_params), do: list(%{})

  @doc """
  One incident room as its report reads it: the room, the message it was
  opened from (`alert`), what people said in it and what Ryker answered there
  (`conversation`), its lifecycle, the records its investigation wrote, its
  latest publication and what the investigation cost (`accounting`).

  The room carries its milestones as times (`channel_created_at`,
  `invited_at`, `ready_at`, `stopped_at`, `closed_at`), where its
  investigation stands (`episode_state`), the names of its environment and
  repository, and, for a room Ryker closed, the note it wrote about where its
  words went (`closed_note`). No other saved error leaves the Failures page.
  Message text is redacted before it leaves here.
  """
  def fetch(ref) when is_binary(ref) and byte_size(ref) <= 1_024 do
    found = ref |> IncidentRoom.Query.by_ref() |> IncidentRoom.Query.limit_to(1) |> Repo.one()

    case found do
      nil ->
        :not_found

      room ->
        episode = if room.episode_id, do: Repo.one(Episode.Query.by_id(room.episode_id))
        names = RepositoryNames.all()
        secrets = InspectionRedactor.configured_secrets()
        alert = alert(room, secrets)

        {:ok,
         %{
           accounting: accounting(room.episode_id),
           alert: alert,
           conversation: conversation(room.episode_id, alert, secrets),
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
      invite_user_refs: room.invite_user_refs,
      invite_user_group_refs: room.invite_user_group_refs,
      requested_by: room.requested_by_actor_ref,
      private: room.private,
      # The investigation starts in the same transaction that makes the room
      # ready, so its request's creation is when it did.
      ready_at: episode && episode.inserted_at,
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

  # The message the room was opened from: the alert, or what someone asked,
  # as the request in its thread first read it.
  defp alert(%IncidentRoom{source_episode_id: nil}, _secrets), do: nil

  defp alert(room, secrets) do
    room.source_episode_id
    |> IncidentReport.Query.messages()
    |> IncidentReport.Query.ordered_by_occurred_at()
    |> IncidentReport.Query.limit_to(1)
    |> Repo.one()
    |> message(secrets)
  end

  # What people said in the room and what Ryker answered there, oldest first:
  # the newest two hundred of each, without the alert when the investigation
  # began in the alert's own thread.
  defp conversation(nil, _alert, _secrets), do: []

  defp conversation(episode_id, alert, secrets) do
    people =
      episode_id
      |> IncidentReport.Query.messages()
      |> IncidentReport.Query.ordered_by_occurred_at_desc()
      |> IncidentReport.Query.limit_to(@detail_limit)
      |> Repo.all()
      |> Enum.reject(&(alert && &1.id == alert.id))
      |> Enum.map(&message(&1, secrets))

    ryker =
      episode_id
      |> IncidentReport.Query.replies(@detail_limit)
      |> Repo.all()
      |> Enum.map(
        &%{at: &1.at, from: :ryker, id: &1.id, text: redacted(&1.text, secrets), workspace: nil}
      )

    Enum.sort_by(people ++ ryker, &DateTime.to_unix(&1.at, :microsecond))
  end

  # Who said it, as the request page's thread says it: a Slack person by name,
  # the console's own person as "You", an app or a system as the place it
  # posted from. The words stay as written, redacted; the page renders their
  # formatting and names their mentions from `workspace`.
  defp message(nil, _secrets), do: nil

  defp message(entry, secrets) do
    %{
      at: entry.at,
      from: sender(entry),
      id: entry.id,
      place: place(entry.conversation_ref),
      text: redacted(entry.text, secrets),
      workspace: if(entry.source_kind == "slack", do: entry.source_ref)
    }
  end

  # Where it was said, by the name Slack gave it; never a channel's raw ID
  # while Slack has not named it yet.
  defp place("slack:" <> _ = ref), do: if(Names.named?(ref), do: Names.destination(ref))
  defp place(ref), do: Names.destination(ref)

  defp sender(%{actor_kind: :user, source_kind: "slack"} = entry),
    do: {:person, Names.person(entry.source_ref, entry.actor_ref)}

  # Someone in Chat: the person who signed in, or the local console's "You".
  defp sender(%{actor_kind: :user, source_kind: "control_plane", actor_ref: actor}) do
    case ConsolePeople.identity(actor) do
      {:person, _login} -> {:person, ConsolePeople.person(actor)}
      :local -> :you
      nil -> :someone
    end
  end

  defp sender(%{actor_kind: :user}), do: :someone
  defp sender(_entry), do: :app

  defp redacted(nil, _secrets), do: nil

  defp redacted(text, secrets) do
    case InspectionRedactor.artifact(text, secrets: secrets, max_bytes: 12_000).text do
      nil -> nil
      text -> String.trim(text)
    end
  end

  # What the investigation's model work cost, the way the request page counts it.
  defp accounting(nil), do: nil

  defp accounting(episode_id) do
    nil
    |> Execution.Query.ledger("all")
    |> Execution.Query.by_episode_id(episode_id)
    |> UsageProjection.totals()
  end

  defp lifecycle(room) do
    room.id
    |> IncidentRoomLifecycleEvent.Query.by_room_id()
    |> IncidentRoomLifecycleEvent.Query.ordered_by_occurred_at()
    |> IncidentRoomLifecycleEvent.Query.limit_to(@detail_limit)
    |> IncidentRoomLifecycleEvent.Query.select_timeline()
    |> Repo.all()
  end

  # The newest records, oldest first: the page leads with the latest update,
  # which the oldest two hundred of a long investigation lack.
  defp records(nil), do: []

  defp records(episode_id) do
    episode_id
    |> Record.Query.by_episode_id()
    |> Record.Query.ordered_by_sequence_desc()
    |> Record.Query.limit_to(@detail_limit)
    |> Repo.all()
    |> Enum.reverse()
    |> Enum.map(&record/1)
  end

  defp publication(nil, _names), do: nil

  defp publication(episode_id, names) do
    episode_id
    |> IncidentReport.Query.latest_publication()
    |> Repo.one()
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
  # person's request or because its channel was deleted, or archived or left
  # before setup finished, for whoever opens the room later: whether it said
  # so in Slack and where a reply it still owed waits.
  defp closed_note(%IncidentRoom{status: :closed, last_error_code: code} = room)
       when code in [
              "incident_room_closed",
              "incident_room_deleted",
              "incident_room_archived",
              "incident_room_left"
            ],
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

  defp incident_status(query, status), do: IncidentReport.Query.by_status(query, status)

  defp incident_search(query, nil), do: query

  defp incident_search(query, search),
    do: IncidentReport.Query.matching(query, Search.contains(search))

  defp sanitize_publication(nil), do: nil

  defp sanitize_publication(publication) do
    Map.put(publication, :last_error, FailureDetail.project(publication.last_error))
  end
end
