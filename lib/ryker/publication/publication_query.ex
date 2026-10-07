defmodule Ryker.Publication.PublicationQuery do
  @moduledoc "Changes Work published, for every read of `episode_publications`."
  import Ecto.Query
  alias Ryker.Episodes.EpisodeQuery
  alias Ryker.Publication.{Followup, Publication}
  alias Ryker.Records.Record
  alias Ryker.Work.Session

  def all, do: from(publications in Publication, as: :episode_publications)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [episode_publications: p], p.id == ^id)

  def by_episode_id(queryable \\ all(), episode_id),
    do: where(queryable, [episode_publications: p], p.episode_id == ^episode_id)

  def by_ref(queryable \\ all(), ref),
    do: where(queryable, [episode_publications: p], p.ref == ^ref)

  @doc "The publication of the offer record `record_ref`."
  def for_record_ref(record_ref) do
    from(p in all(),
      join: r in Record,
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
      join: s in Session,
      as: :episode_work_sessions,
      on: s.id == p.session_id and s.episode_id == p.episode_id,
      where:
        p.status != :review_pending or
          p.episode_id not in subquery(EpisodeQuery.select_ids(EpisodeQuery.working_on_turns())),
      where:
        p.status in ^statuses and
          (is_nil(p.last_error_code) or p.last_error_code not in ^conflicts) and
          (is_nil(p.next_attempt_at) or p.next_attempt_at <= ^now) and
          (is_nil(p.lease_expires_at) or p.lease_expires_at <= ^now)
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
  def next_due_after(since, statuses) do
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
  def with_open_pull_request(repository, number) do
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

  def unpublished(queryable),
    do: where(queryable, [episode_publications: p], p.status != :published)

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

  def newest_first(queryable),
    do: order_by(queryable, [episode_publications: p], desc: p.inserted_at, desc: p.id)

  def select_statuses(queryable), do: select(queryable, [episode_publications: p], p.status)
  def limit_to(queryable, count), do: limit(queryable, ^count)
end
