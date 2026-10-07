defmodule Ryker.ControlPlane.CurrentInput.Query do
  @moduledoc "Current source revisions for conversation views; retained model artifacts stay immutable."
  import Ecto.Query
  alias Ryker.Ingress.Inbox.Entry

  @doc """
  The text a current revision shows, as SQL: nothing once retention pruned it,
  a marker once the message was deleted, otherwise its bounded text.
  """
  defmacro visible_text(pruned_at, event_kind, content) do
    quote do
      fragment(
        "CASE WHEN ? IS NOT NULL THEN NULL WHEN ? = 'delete' THEN 'Message deleted' ELSE left(?::jsonb->>'text', 12000) END",
        unquote(pruned_at),
        unquote(event_kind),
        unquote(content)
      )
    end
  end

  @doc """
  Like `visible_text/3`, but for a request title: a source with no text of its
  own falls through to its comment or review body, its first attachment or
  block, or its first file name.
  """
  defmacro visible_preview(pruned_at, event_kind, content) do
    quote do
      fragment(
        "CASE WHEN ? IS NOT NULL THEN NULL WHEN ? = 'delete' THEN 'Message deleted' ELSE (SELECT left(COALESCE(NULLIF(source ->> 'text', ''), 'Answered \"' || (source ->> 'choice') || '\"', source #>> '{payload,comment,body}', source #>> '{payload,review,body}', source #>> '{attachments,0,title}', source #>> '{attachments,0,pretext}', source #>> '{attachments,0,text}', source #>> '{attachments,0,fallback}', source #>> '{blocks,0,text,text}', source #>> '{files,0,name}'), 12000) FROM (SELECT ?::jsonb AS source) AS payload) END",
        unquote(pruned_at),
        unquote(event_kind),
        unquote(content)
      )
    end
  end

  @doc """
  What a message that has not become work reads as, as SQL: the decision
  routing recorded for it, `routing` while a routing worker holds its lease,
  otherwise where it stands (pending, blocked, superseded). `now` decides
  whether a lease still holds; one that ran out is waiting to be picked up
  again, not being routed.

  Activity's rows and a message page's thread read it here, so a message never
  says one thing in the list and another beside its neighbours.
  """
  defmacro input_state(entry, now) do
    quote do
      fragment(
        "CASE WHEN ? = 'decided' THEN COALESCE(?::text, 'decided') WHEN ? = 'pending' AND ? IS NOT NULL AND ? > ? THEN 'routing' ELSE ?::text END",
        unquote(entry).status,
        unquote(entry).decision_action,
        unquote(entry).status,
        unquote(entry).lease_ref,
        unquote(entry).lease_expires_at,
        type(unquote(now), :utc_datetime_usec),
        unquote(entry).status
      )
    end
  end

  @doc """
  The current revision of the message the `:revision` binding is a revision
  of, for a lateral join: its highest revision, the latest recorded among
  equals. It is one read of `ingress_inbox_current_revisions` a message;
  ranking every revision in the inbox to find each current one read the
  whole table on every page that showed a message (2026-10-04 review).
  """
  def current do
    from(current in Entry,
      where:
        current.native_input_id == parent_as(:revision).native_input_id and
          current.execution_mode == parent_as(:revision).execution_mode,
      order_by: [desc: current.revision, desc: current.inserted_at, desc: current.id],
      limit: 1
    )
  end

  @doc """
  The messages of an episode, each once, as they read now: the time the
  first revision arrived and everything else from the current one.
  """
  def for_episode(id) do
    first_revisions =
      from(seed in Entry,
        where: seed.episode_id == ^id,
        distinct: seed.native_input_id,
        order_by: [asc: seed.native_input_id, asc: seed.occurred_at, asc: seed.id]
      )

    from(seed in subquery(first_revisions),
      as: :revision,
      inner_lateral_join: current in subquery(current()),
      on: true,
      select: %{
        id: current.id,
        occurred_at: seed.occurred_at,
        occurred_at_source: current.occurred_at_source,
        inserted_at: current.inserted_at,
        content: current.content,
        source_envelope: current.source_envelope,
        operational_pruned_at: current.operational_pruned_at,
        event_kind: current.event_kind,
        event_ref: current.event_ref,
        dedupe_key: current.dedupe_key,
        source_item_ref: current.source_item_ref,
        revision: current.revision,
        execution_mode: current.execution_mode,
        destination_transport: current.destination_transport,
        destination_conversation_ref: current.destination_conversation_ref,
        destination_thread_ref: current.destination_thread_ref,
        actor_kind: current.actor_kind,
        actor_ref: current.actor_ref,
        source_kind: current.source_kind,
        source_ref: current.source_ref,
        repository_ref: current.repository_ref
      }
    )
  end
end
