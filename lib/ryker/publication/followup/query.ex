defmodule Ryker.Publication.Followup.Query do
  @moduledoc "How each published pull request is followed up, for every read of `episode_publication_followups`."
  use Ryker, :query
  alias Ryker.Episodes
  alias Ryker.Publication.{Followup, Publication}

  def all, do: from(followups in Followup, as: :episode_publication_followups)

  def by_publication_ids(queryable \\ all(), publication_ids),
    do: where(queryable, [episode_publication_followups: f], f.publication_id in ^publication_ids)

  @doc "Each follow-up's pull request state, as `{publication_id, pr_state}`."
  def select_states(queryable),
    do: select(queryable, [episode_publication_followups: f], {f.publication_id, f.pr_state})

  def by_publication_id(queryable \\ all(), publication_id),
    do: where(queryable, [episode_publication_followups: f], f.publication_id == ^publication_id)

  @doc """
  The follow-ups a poll can claim, each with its publication as
  `:episode_publications`: those whose publication is still published. A
  task whose newer change is back in review, or blocked there, leaves its pull
  request's poll due and waiting on purpose; readiness counts by this too.
  """
  def pollable do
    from(f in all(),
      join: p in Publication,
      as: :episode_publications,
      on: p.id == f.publication_id and p.episode_id == f.episode_id,
      where: p.status == :published
    )
  end

  def poll_due_at(queryable, now),
    do: where(queryable, [episode_publication_followups: f], f.next_poll_at <= ^now)

  @doc "Follow-ups whose poll is due at `now` and whose lease, if any, ran out."
  def due_unleased_at(queryable, now) do
    where(
      queryable,
      [episode_publication_followups: f],
      f.next_poll_at <= ^now and (is_nil(f.lease_expires_at) or f.lease_expires_at <= ^now)
    )
  end

  @doc "When pollable follow-ups fall due after `since`, as `[next_poll_at, lease_expires_at]`."
  def select_next_due_after(since) do
    from(f in pollable(),
      select: [
        filter(min(f.next_poll_at), f.next_poll_at > ^since),
        filter(min(f.lease_expires_at), f.lease_expires_at > ^since)
      ]
    )
  end

  @doc "The follow-up of publication `publication_ref`, with the publication, as `{followup, publication}`."
  def by_publication_ref(publication_ref) do
    from(f in all(),
      join: p in Publication,
      as: :episode_publications,
      on: p.id == f.publication_id,
      where: p.ref == ^publication_ref,
      select: {f, p}
    )
  end

  @doc """
  The follow-up of pull request `number` in `repository` that a published
  publication recorded, while its state is one of `states`.
  """
  def by_pull_request(repository, number, states) do
    from(f in all(),
      join: p in Publication,
      on: p.id == f.publication_id,
      where:
        p.status == :published and p.github_repository == ^repository and
          p.pull_request_number == ^number and f.pr_state in ^states
    )
  end

  @doc """
  The merged pull requests of `repository` still followed for deployment
  signals at `now` that a signal names by `references` (a URL, a branch, a
  head or a merge commit) or by `branch_references`, as `{followup,
  publication}`, by publication.
  """
  def merged_matching(repository, references, branch_references, now) do
    from(f in all(),
      join: p in Publication,
      on: p.id == f.publication_id,
      where:
        p.status == :published and p.repository == ^repository and f.pr_state == :merged and
          f.deadline_at > ^now and not is_nil(f.merge_sha),
      where:
        p.pull_request_url in ^references or p.branch_ref in ^references or
          p.branch_ref in ^branch_references or p.commit_sha in ^references or
          f.merge_sha in ^references,
      order_by: [asc: p.id],
      select: {f, p}
    )
  end

  def ordered_by_next_poll_at(queryable),
    do: order_by(queryable, [episode_publication_followups: f], asc: f.next_poll_at, asc: f.id)

  def select_with_publications(queryable) do
    select(
      queryable,
      [episode_publication_followups: f, episode_publications: p],
      {f, p}
    )
  end

  def limit_to(queryable, count), do: limit(queryable, ^count)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
  def lock_next_free(queryable), do: lock(queryable, "FOR UPDATE SKIP LOCKED")

  @doc "Follow-ups of pull requests that were merged or closed."
  def ended(queryable),
    do: where(queryable, [episode_publication_followups: f], f.pr_state in [:merged, :closed])

  @doc """
  The live pull requests opened between `from` and `to`, and every one still
  open, newest first, each with its publication and conversation. A pull
  request is opened when its publication first goes out, which is when its
  follow-up starts; a follow-up rearmed later keeps that time.
  """
  def pull_requests(from, to) do
    from(followup in all(),
      join: publication in Publication,
      on: publication.id == followup.publication_id,
      join: episode in Episodes.Episode,
      on: episode.id == followup.episode_id and episode.execution_mode == :live,
      where:
        (followup.inserted_at >= ^from and followup.inserted_at < ^to) or
          followup.pr_state in [:open, :stale],
      order_by: [desc: followup.inserted_at, desc: followup.id],
      select: %{
        state: followup.pr_state,
        opened_at: followup.inserted_at,
        merged_at: followup.merged_at,
        number: publication.pull_request_number,
        url: publication.pull_request_url,
        title: publication.title,
        repository: publication.github_repository,
        conversation: episode.destination_conversation_ref
      }
    )
  end
end
