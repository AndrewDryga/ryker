defmodule Ryker.Publication.Publication.Query do
  @moduledoc "Changes Work published, for every read of `episode_publications`."
  use Ryker, :query
  alias Ryker.Episodes
  alias Ryker.Publication.{Followup, Publication}
  alias Ryker.Records
  alias Ryker.Slack
  alias Ryker.Work

  def all, do: from(publications in Publication, as: :episode_publications)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [episode_publications: p], p.id == ^id)

  def by_episode_id(queryable \\ all(), episode_id),
    do: where(queryable, [episode_publications: p], p.episode_id == ^episode_id)

  def by_record_id(queryable \\ all(), record_id),
    do: where(queryable, [episode_publications: p], p.record_id == ^record_id)

  @doc "Exact offer record IDs consumed by this episode's canonical publication custody."
  def select_consumed_record_ids(queryable \\ all(), episode_id, record_ids) do
    queryable
    |> where(
      [episode_publications: p],
      p.episode_id == ^episode_id and p.record_id in ^record_ids
    )
    |> select([episode_publications: p], p.record_id)
  end

  @doc "The latest publication and its same-episode follow-up in one revision-consistent read."
  def model_state(episode_id, repository) do
    from(p in all(),
      left_join: f in Followup,
      on: f.publication_id == p.id and f.episode_id == p.episode_id,
      where: p.episode_id == ^episode_id and p.repository == ^repository,
      order_by: [desc: p.inserted_at, desc: p.id],
      limit: 1,
      select: {p, f}
    )
  end

  @doc "At most three confirmed task children in the caller's exact retained destination and read set."
  def related_model_states(queryable \\ all(), episode, repositories) do
    roots = Episodes.Episode.Query.retained_context_lineage(episode)

    queryable
    |> related_task_children()
    |> confirmed_related_tasks(roots, episode.id, repositories)
    |> retained_related_tasks()
    |> in_related_execution_mode(episode.execution_mode)
    |> in_related_transport(episode.destination_transport)
    |> in_related_conversation(episode.destination_conversation_ref)
    |> in_related_thread(episode.destination_thread_ref)
    |> order_by([episode_publications: p], desc: p.inserted_at, desc: p.id)
    |> limit(3)
  end

  defp related_task_children(queryable) do
    from(p in queryable,
      join: r in Records.Record,
      as: :related_task_offer,
      on: r.confirmed_episode_id == p.episode_id,
      join: c in Episodes.Episode,
      as: :related_task_child,
      on: c.id == p.episode_id and c.linked_episode_id == r.episode_id,
      join: e in Episodes.Episode,
      as: :related_task_root,
      on: e.id == r.episode_id,
      join: s in Work.Session,
      on: s.id == p.session_id and s.episode_id == c.id and s.repository_ref == p.repository,
      left_join: f in Followup,
      on: f.publication_id == p.id and f.episode_id == p.episode_id,
      select: {p, f, c.id, r.ref}
    )
  end

  defp confirmed_related_tasks(query, roots, episode_id, repositories) do
    where(
      query,
      [
        episode_publications: p,
        related_task_offer: r,
        related_task_child: c,
        related_task_root: e
      ],
      r.kind == "task_offer" and r.status == :confirmed and e.id in subquery(roots) and
        c.id != ^episode_id and p.repository in ^repositories
    )
  end

  defp retained_related_tasks(query) do
    where(
      query,
      [related_task_root: e, related_task_child: c],
      is_nil(e.history_pruned_at) and is_nil(c.history_pruned_at)
    )
  end

  defp in_related_execution_mode(query, mode) do
    where(
      query,
      [related_task_root: e, related_task_child: c],
      e.execution_mode == ^mode and c.execution_mode == ^mode
    )
  end

  defp in_related_transport(query, transport) do
    where(
      query,
      [episode_publications: p, related_task_root: e, related_task_child: c],
      e.destination_transport == ^transport and c.destination_transport == ^transport and
        p.destination_transport == ^transport
    )
  end

  defp in_related_conversation(query, conversation_ref) do
    where(
      query,
      [episode_publications: p, related_task_root: e, related_task_child: c],
      e.destination_conversation_ref == ^conversation_ref and
        c.destination_conversation_ref == ^conversation_ref and
        p.destination_conversation_ref == ^conversation_ref
    )
  end

  defp in_related_thread(query, thread_ref) do
    where(
      query,
      [episode_publications: p, related_task_root: e, related_task_child: c],
      fragment("? IS NOT DISTINCT FROM ?", e.destination_thread_ref, ^thread_ref) and
        fragment("? IS NOT DISTINCT FROM ?", c.destination_thread_ref, ^thread_ref) and
        fragment("? IS NOT DISTINCT FROM ?", p.destination_thread_ref, ^thread_ref)
    )
  end

  def by_ref(queryable \\ all(), ref),
    do: where(queryable, [episode_publications: p], p.ref == ^ref)

  @doc "The publication of the offer record `record_ref`."
  def by_record_ref(record_ref) do
    from(p in all(),
      join: r in Records.Record,
      on: r.id == p.record_id,
      where: r.ref == ^record_ref,
      select: p
    )
  end

  @doc """
  Publications a worker may lease at `now`, each with its session as
  `:episode_work_sessions`: in one of `statuses`, not stopped on a conflict in
  `conflicts`, due, unleased, and, while waiting for review, with no Work
  turn of its episode running.
  """
  def claimable_at(now, statuses, conflicts) do
    from(p in all(),
      join: s in Work.Session,
      as: :episode_work_sessions,
      on: s.id == p.session_id and s.episode_id == p.episode_id,
      where:
        p.status != :review_pending or
          p.episode_id not in subquery(
            Episodes.Episode.Query.select_ids(Episodes.Episode.Query.working_on_turns())
          ),
      where:
        p.status in ^statuses and
          (is_nil(p.last_error_code) or p.last_error_code not in ^conflicts) and
          (is_nil(p.next_attempt_at) or p.next_attempt_at <= ^now) and
          (is_nil(p.lease_expires_at) or p.lease_expires_at <= ^now)
    )
    |> with_notification_destination()
  end

  defp with_notification_destination(query) do
    pending_card =
      from(card in Slack.TaskCard,
        where:
          card.episode_id == parent_as(:episode_publications).episode_id and
            is_nil(card.thread_ref) and is_nil(card.message_ref),
        select: 1
      )

    from(p in query,
      where:
        p.status not in [:review_ready, :published_ready] or
          like(p.review_request_ref, "task-readiness:%") or not exists(pending_card)
    )
  end

  @doc "A suppressed task reply still owed after the latest candidate finished."
  def pending_reply(queryable \\ all(), conflicts) do
    reported = reported_reply()

    queryable
    |> with_reply_turns()
    |> with_reportable_outcome(conflicts)
    |> with_suppressed_reply()
    |> where(not exists(reported))
    |> order_by([pending_reply_turn: t], asc: t.accepted_at, asc: t.id)
    |> limit(1)
    |> select([episode_publications: p, pending_reply_turn: t], {p, t})
  end

  defp reported_reply do
    from(o in Episodes.Origin,
      where: o.episode_id == parent_as(:episode_publications).episode_id,
      where: o.source_kind == "system" and o.source_ref == "publication-result",
      where:
        fragment(
          "? LIKE ('publication-result:%:' || ?::text || ':%')",
          o.native_input_id,
          parent_as(:pending_reply_turn).id
        ) or
          (fragment(
             "? LIKE ('publication-result:' || ?::text || ':g' || ?::text || ':%:' || ?)",
             o.native_input_id,
             parent_as(:episode_publications).id,
             parent_as(:episode_publications).review_generation,
             parent_as(:episode_publications).status
           ) and
             o.transport ==
               fragment(
                 "?::jsonb->>'transport'",
                 parent_as(:pending_reply_turn).delivery_target
               ) and
             o.conversation_ref ==
               fragment(
                 "?::jsonb->>'conversation_ref'",
                 parent_as(:pending_reply_turn).delivery_target
               ) and
             fragment(
               "? IS NOT DISTINCT FROM (?::jsonb->>'thread_ref')",
               o.thread_ref,
               parent_as(:pending_reply_turn).delivery_target
             )),
      select: 1
    )
  end

  defp with_reply_turns(queryable) do
    from([episode_publications: p] in queryable,
      join: e in Episodes.Episode,
      as: :publication_episode,
      on: e.id == p.episode_id,
      join: source in Work.Turn,
      as: :publication_source_turn,
      on:
        source.episode_id == p.episode_id and
          p.review_request_ref == fragment("'task-readiness:' || ?::text", source.id),
      join: t in Work.Turn,
      as: :pending_reply_turn,
      on: t.episode_id == p.episode_id,
      join: r in Records.Record,
      as: :pending_reply_offer,
      on: r.turn_id == t.id and r.episode_id == t.episode_id,
      join: s in Work.Session,
      as: :pending_reply_session,
      on: s.id == t.session_id and s.repository_ref == p.repository
    )
  end

  defp with_reportable_outcome(queryable, conflicts) do
    from([episode_publications: p] in queryable,
      where: is_nil(p.lease_ref),
      where:
        p.status in [:published, :reviewed, :blocked] or
          (p.status == :discarded and p.discarded_reason == :review_session_closed) or
          (p.status in [:review_pending, :publish_pending] and
             (p.last_error_code in ^conflicts or
                (p.attempt_count >= 3 and not is_nil(p.last_error_code))))
    )
  end

  defp with_suppressed_reply(queryable) do
    from([publication_episode: e, pending_reply_turn: t, pending_reply_offer: r] in queryable,
      where: e.state == :complete and is_nil(e.history_pruned_at),
      where: t.status == :settled and is_nil(t.delivery_ref) and not is_nil(t.delivery_target),
      where: not is_nil(t.result_ref) and t.continuation == ^%{"kind" => "complete"},
      where: fragment("?::jsonb->'result'->>'delivery' = 'reply'", t.validation_intent),
      where: r.kind == "publication_offer" and r.operation_id == "host:publication:ready"
    )
  end

  @doc """
  The oldest of `claimable_at/3`'s publications, with its session, both locked
  and skipped while another worker holds them.
  """
  def next_claimable(now, statuses, conflicts) do
    from(
      [episode_publications: p, episode_work_sessions: s] in claimable_at(
        now,
        statuses,
        conflicts
      ),
      order_by: [asc: p.inserted_at, asc: p.id],
      limit: 1,
      select: {p, s},
      lock: "FOR UPDATE SKIP LOCKED"
    )
  end

  @doc """
  When publications in `statuses` fall due after `since`, as
  `[next_attempt_at, lease_expires_at]`.
  """
  def select_next_due_after(since, statuses) do
    from(p in all(),
      where: p.status in ^statuses,
      select: [
        filter(min(p.next_attempt_at), p.next_attempt_at > ^since),
        filter(min(p.lease_expires_at), p.lease_expires_at > ^since)
      ]
    )
  end

  @doc """
  The publications whose open pull request is `number` in `repository`,
  whatever update of it is in review: at most two, so a caller can tell one
  from several.
  """
  def by_open_pull_request(repository, number) do
    from(p in all(),
      join: f in Followup,
      on: f.publication_id == p.id and f.episode_id == p.episode_id,
      where:
        p.status != :discarded and p.github_repository == ^repository and
          p.pull_request_number == ^number and f.pr_state == :open,
      order_by: [asc: p.id],
      limit: 2,
      select: p
    )
  end

  @doc "Session `session_id`'s publications approved by `approval_ref`; at most two."
  def by_approval(session_id, approval_ref) do
    from(p in all(),
      where: p.session_id == ^session_id and p.approval_ref == ^approval_ref,
      limit: 2
    )
  end

  def select_episode_ids(queryable),
    do: select(queryable, [episode_publications: p], p.episode_id)

  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")

  def by_session_id(queryable \\ all(), session_id),
    do: where(queryable, [episode_publications: p], p.session_id == ^session_id)

  def published(queryable),
    do: where(queryable, [episode_publications: p], p.status == :published)

  @doc """
  Publications that may still publish: neither published nor discarded. A
  blocked one waits for someone to recover it from its session's workspace.
  """
  def pending(queryable \\ all()),
    do: where(queryable, [episode_publications: p], p.status not in [:published, :discarded])

  @doc "Readiness reviews whose lease is held at `now`."
  def reviewing_at(queryable \\ all(), now) do
    where(
      queryable,
      [episode_publications: p],
      p.status == :review_pending and p.lease_expires_at > ^now
    )
  end

  @doc "When the first review lease held after `since` runs out."
  def next_review_expiry_after(since) do
    all()
    |> reviewing_at(since)
    |> select([episode_publications: p], min(p.lease_expires_at))
  end

  def ordered_by_recent(queryable),
    do: order_by(queryable, [episode_publications: p], desc: p.inserted_at, desc: p.id)

  def select_statuses(queryable), do: select(queryable, [episode_publications: p], p.status)
  def limit_to(queryable, count), do: limit(queryable, ^count)
end
