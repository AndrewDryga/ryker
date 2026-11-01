defmodule Ryker.GitHub.CommentActivity.Query do
  @moduledoc "Live GitHub comment admissions and exact active episode inputs, including PR follow-ups without Inbox rows."
  use Ryker, :query
  alias Ryker.Episodes
  alias Ryker.Ingress
  alias Ryker.Publication
  alias Ryker.Work

  def pending_entries(name, repository_id) do
    conversation = "github:#{name}:repository:#{repository_id}"

    from(e in Ingress.Inbox.Entry,
      as: :source,
      where:
        e.source_kind == "github" and e.source_ref == ^name and
          e.destination_transport == "github" and e.destination_conversation_ref == ^conversation,
      where:
        e.execution_mode == :live and e.actor_kind == :user and
          e.event_kind in [:message, :edit] and e.status == :pending,
      select: e.source_item_ref
    )
    |> current_revision()
  end

  def active_origins(name, repository_id) do
    conversation = "github:#{name}:repository:#{repository_id}"

    from(o in Episodes.Origin,
      as: :source,
      join: p in Episodes.Episode,
      as: :episode,
      on: p.id == o.episode_id,
      where:
        o.source_kind == "github" and o.source_ref == ^name and
          o.transport == "github" and o.conversation_ref == ^conversation,
      where:
        p.execution_mode == :live and p.state != :cancelled and
          like(o.actor_ref, "github:user:%"),
      select: o.source_item_ref
    )
    |> with_joined_owner()
    |> active_inputs()
    |> current_revision()
  end

  def pending_feedback(name, repository_id) do
    conversation = "github:#{name}:repository:#{repository_id}"

    feedback =
      from(f in Publication.LifecycleEvent,
        join: p in Episodes.Episode,
        on: p.id == f.episode_id,
        where:
          f.kind == :review_feedback and f.source_transport == "github" and
            f.source_conversation_ref == ^conversation and f.wakeup_state == :pending,
        where: p.execution_mode == :live and p.state != :cancelled,
        select: %{
          source_ref: fragment("?::jsonb #>> '{source,ref}'", f.observation),
          native_input_id: fragment("?::jsonb ->> 'native_input_id'", f.observation),
          revision: fragment("(?::jsonb ->> 'revision')::bigint", f.observation),
          source_item_ref: f.source_item_ref,
          actor_kind: fragment("?::jsonb #>> '{actor,kind}'", f.observation),
          event_kind: fragment("?::jsonb ->> 'event_kind'", f.observation)
        }
      )

    from(f in subquery(feedback),
      as: :source,
      where:
        f.source_ref == ^name and f.actor_kind == "user" and
          f.event_kind in ["message", "edit"],
      select: f.source_item_ref
    )
    |> current_revision()
  end

  defp with_joined_owner(queryable) do
    from([episode: p] in queryable,
      left_join: t in Work.Turn,
      as: :turn,
      on:
        t.episode_id == p.id and
          ((p.owner_kind == :turn and t.turn_ref == p.owner_ref) or
             t.status == :delivery_pending)
    )
  end

  defp active_inputs(queryable) do
    where(
      queryable,
      [source: o, episode: p, turn: t],
      ((p.state == :working and
          (o.input_ref in p.active_input_refs or o.input_ref in p.queued_input_refs)) or
         (t.status == :delivery_pending and o.input_ref in t.selected_input_refs)) and
        (is_nil(t.id) or t.status != :blocked)
    )
  end

  # Inbox and publication feedback are separate admission paths. A later edit
  # or deletion in either path supersedes an older active origin immediately.
  defp current_revision(queryable) do
    newer_entry =
      from(n in Ingress.Inbox.Entry,
        where:
          n.source_kind == "github" and n.execution_mode == :live and
            n.source_ref == parent_as(:source).source_ref and
            n.native_input_id == parent_as(:source).native_input_id,
        where:
          n.revision > parent_as(:source).revision or
            (n.revision == parent_as(:source).revision and n.event_kind == :delete),
        select: 1
      )

    where(queryable, not exists(subquery(newer_entry)))
    |> without_newer_feedback()
  end

  defp without_newer_feedback(queryable) do
    newer_feedback =
      from(f in Publication.LifecycleEvent,
        where:
          f.kind == :review_feedback and
            fragment("?::jsonb #>> '{source,ref}'", f.observation) ==
              parent_as(:source).source_ref and
            fragment("?::jsonb ->> 'native_input_id'", f.observation) ==
              parent_as(:source).native_input_id,
        where:
          fragment("(?::jsonb ->> 'revision')::bigint", f.observation) >
            parent_as(:source).revision or
            (fragment("(?::jsonb ->> 'revision')::bigint", f.observation) ==
               parent_as(:source).revision and
               fragment("?::jsonb ->> 'event_kind'", f.observation) == "delete"),
        select: 1
      )

    where(queryable, not exists(subquery(newer_feedback)))
  end
end
