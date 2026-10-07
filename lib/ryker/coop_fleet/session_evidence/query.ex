defmodule Ryker.CoopFleet.SessionEvidence.Query do
  @moduledoc "What each Coop session showed of its sandbox, for every read of `coop_session_evidence`."
  use Ryker, :query
  alias Ryker.CoopFleet.SessionEvidence

  def all, do: from(evidence in SessionEvidence, as: :coop_session_evidence)

  @doc "Every capture of session `session_id`, oldest state first."
  def by_session_id(session_id) do
    all()
    |> where([coop_session_evidence: e], e.session_id == ^session_id)
    |> order_by([coop_session_evidence: e], asc: e.first_captured_at, asc: e.id)
  end

  @doc "The latest capture of each session of episode `episode_id`, newest last."
  def latest_for_episode(episode_id) do
    latest =
      from(e in all(),
        where: e.episode_id == ^episode_id,
        distinct: e.session_id,
        order_by: [asc: e.session_id, desc: e.last_captured_at, desc: e.id]
      )

    from(row in subquery(latest), order_by: [asc: row.last_captured_at, asc: row.id])
  end

  @doc """
  The update that records the same state of session `session_id` observed
  again at `captured_at`: one more capture, and the latest observation moves
  forward but never back.
  """
  def observed_again(session_id, fingerprint, captured_at) do
    from(e in all(),
      where: e.session_id == ^session_id and e.content_fingerprint == ^fingerprint,
      update: [
        set: [last_captured_at: fragment("GREATEST(?, ?)", ^captured_at, e.last_captured_at)],
        inc: [capture_count: 1]
      ],
      select: e
    )
  end
end
