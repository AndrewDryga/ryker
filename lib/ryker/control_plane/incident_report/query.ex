defmodule Ryker.ControlPlane.IncidentReport.Query do
  @moduledoc """
  What the incident room pages read (`Ryker.ControlPlane.IncidentProjection`):
  the directory with each room's investigation and latest publication, its
  search and status filter, and, for one room's report, the messages people
  said in it, what Ryker answered there and its latest publication.
  """
  use Ryker, :query
  alias Ryker.ControlPlane.CurrentInput
  alias Ryker.Episodes
  alias Ryker.Ingress
  alias Ryker.Publication
  alias Ryker.Work
  require Ryker.ControlPlane.CurrentInput.Query

  @doc """
  Rooms whose ref, title, repository, workspace or either channel contains
  `pattern`.
  """
  def matching(queryable, pattern) do
    where(
      queryable,
      [slack_incident_rooms: r],
      ilike(r.ref, ^pattern) or ilike(r.title, ^pattern) or
        ilike(r.repository_ref, ^pattern) or ilike(r.workspace_ref, ^pattern) or
        ilike(r.source_channel_ref, ^pattern) or ilike(r.channel_ref, ^pattern)
    )
  end

  def by_status(queryable, status),
    do: where(queryable, [slack_incident_rooms: r], r.status == ^status)

  @doc "Each room as the directory lists it, with its latest publication."
  def directory(queryable) do
    latest_publications =
      from(publication in Publication.Publication,
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

    from([slack_incident_rooms: room] in queryable,
      left_join: episode in Episodes.Episode,
      on: episode.id == room.episode_id,
      left_join: publication in subquery(latest_publications),
      on: publication.episode_id == room.episode_id,
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
  end

  @doc """
  The messages people said in `episode_id`'s conversation, each as it reads
  now: `%{actor_kind, actor_ref, at, conversation_ref, id, source_kind,
  source_ref, text}`.
  """
  def messages(episode_id) do
    from([ingress_inbox_entries: entry] in Ingress.Inbox.Entry.Query.all(),
      where: entry.episode_id == ^episode_id and entry.event_kind == :message,
      select: %{
        actor_kind: entry.actor_kind,
        actor_ref: entry.actor_ref,
        at: entry.occurred_at,
        conversation_ref: entry.destination_conversation_ref,
        id: entry.id,
        source_kind: entry.source_kind,
        source_ref: entry.source_ref,
        text:
          CurrentInput.Query.visible_preview(
            entry.operational_pruned_at,
            entry.event_kind,
            entry.content
          )
      }
    )
  end

  def ordered_by_occurred_at(queryable),
    do: order_by(queryable, [ingress_inbox_entries: e], asc: e.occurred_at, asc: e.id)

  def ordered_by_occurred_at_desc(queryable),
    do: order_by(queryable, [ingress_inbox_entries: e], desc: e.occurred_at, desc: e.id)

  def limit_to(queryable, count), do: limit(queryable, ^count)

  @doc "The `limit` latest replies Ryker delivered for `episode_id`, as `%{at, id, text}`."
  def replies(episode_id, limit) do
    from(turn in Work.Turn,
      where:
        turn.episode_id == ^episode_id and not is_nil(turn.delivered_at) and
          fragment("?::jsonb->>'delivery' = 'reply'", turn.delivery_document),
      order_by: [desc: turn.delivered_at, desc: turn.id],
      limit: ^limit,
      select: %{
        at: turn.delivered_at,
        id: turn.id,
        text: fragment("left(?::jsonb->>'message', 12000)", turn.delivery_document)
      }
    )
  end

  @doc "What a report shows of `episode_id`'s latest publication."
  def latest_publication(episode_id) do
    from(publication in Publication.Publication,
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
  end
end
