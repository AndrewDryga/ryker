defmodule Ryker.GitHub.PullRequestActivity.Query do
  @moduledoc "Active owned PRs, including corrections requested by CI and review feedback before their turn starts."
  use Ryker, :query
  alias Ryker.Episodes
  alias Ryker.Publication
  alias Ryker.Work

  def active_publications(repository, now) do
    pending =
      from(l in Publication.LifecycleEvent,
        as: :lifecycle_event,
        where: l.publication_id == parent_as(:publication).id and l.wakeup_state == :pending,
        select: 1
      )

    from(p in Publication.Publication,
      as: :publication,
      join: e in Episodes.Episode,
      as: :episode,
      on: e.id == p.episode_id,
      join: f in Publication.Followup,
      as: :followup,
      on: f.publication_id == p.id,
      left_join: t in Work.Turn,
      as: :turn,
      on: t.episode_id == e.id and t.turn_ref == e.owner_ref,
      where:
        p.github_repository == ^repository and
          not is_nil(p.pull_request_number),
      where:
        e.execution_mode == :live and e.state != :cancelled and
          f.pr_state == :open,
      distinct: true,
      select: p.pull_request_number
    )
    |> having_active_work(pending, now)
  end

  defp having_active_work(queryable, pending, now) do
    where(
      queryable,
      [publication: p, episode: e, turn: t],
      (e.state == :working and (is_nil(t.id) or t.status != :blocked)) or
        (p.status in [:review_pending, :publish_pending] and
           (is_nil(p.last_error_code) or p.lease_expires_at > ^now)) or
        exists(subquery(pending))
    )
  end
end
