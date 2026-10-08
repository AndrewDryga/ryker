defmodule Ryker.Improvement.Candidate.Query do
  @moduledoc "Requests feedback flagged for review, for every read of `improvement_candidates`."
  use Ryker, :query
  alias Ryker.Delivery
  alias Ryker.Improvement.{AnalysisRun, Candidate}
  alias Ryker.Work

  def all, do: from(candidates in Candidate, as: :improvement_candidates)

  def by_id(queryable \\ all(), id),
    do: where(queryable, [improvement_candidates: c], c.id == ^id)

  def by_episode_id(queryable \\ all(), episode_id),
    do: where(queryable, [improvement_candidates: c], c.episode_id == ^episode_id)

  def by_input_id(queryable \\ all(), input_id),
    do: where(queryable, [improvement_candidates: c], c.input_id == ^input_id)

  def kept(queryable \\ all()),
    do: where(queryable, [improvement_candidates: c], is_nil(c.forgotten_at))

  def created_between(queryable, from, to) do
    where(
      queryable,
      [improvement_candidates: c],
      c.inserted_at >= ^from and c.inserted_at < ^to
    )
  end

  def decided_between(queryable, from, to) do
    where(
      queryable,
      [improvement_candidates: c],
      c.decided_at >= ^from and c.decided_at < ^to
    )
  end

  def by_status(queryable, status),
    do: where(queryable, [improvement_candidates: c], c.status == ^status)

  @doc """
  The candidate a worker leases next at `now`, skipping any another worker
  holds: one whose worker stopped renewing its lease, or one that is due and
  either has a run still out at Coop or, with `enabled?`, is still wanted,
  quiet since `quiet` and at rest. With analysis off only what is out at
  Coop is followed, to its stop.
  """
  def next_claimable(now, quiet, enabled?) do
    from(c in all(),
      where: ^claimable(now, quiet, enabled?),
      order_by: [asc: c.last_signal_at, asc: c.id],
      limit: 1,
      lock: "FOR UPDATE SKIP LOCKED"
    )
  end

  defp claimable(now, quiet, true) do
    dynamic(
      [improvement_candidates: c],
      ^stale_lease(now) or
        (^due(now) and (exists(outstanding_run()) or (^wanted(quiet) and ^at_rest())))
    )
  end

  defp claimable(now, _quiet, false) do
    dynamic(
      [improvement_candidates: c],
      ^stale_lease(now) or (^due(now) and exists(outstanding_run()))
    )
  end

  defp stale_lease(now) do
    dynamic(
      [improvement_candidates: c],
      c.analysis == :running and c.lease_expires_at <= ^now
    )
  end

  defp due(now) do
    dynamic(
      [improvement_candidates: c],
      c.analysis == :pending and (is_nil(c.next_attempt_at) or c.next_attempt_at <= ^now)
    )
  end

  defp wanted(quiet) do
    dynamic(
      [improvement_candidates: c],
      is_nil(c.forgotten_at) and c.status != :dismissed and c.last_signal_at <= ^quiet
    )
  end

  # The request has nothing still running: its Work has come to rest, or the
  # quick replies routing chose for the message were delivered or given up.
  defp at_rest do
    running_work =
      from(work in subquery(Work.OwningTurn.Query.work_rest()),
        where: work.episode_id == parent_as(:improvement_candidates).episode_id and work.running
      )

    pending_replies =
      from(response in Delivery.RoutingResponse,
        where:
          response.input_id == parent_as(:improvement_candidates).input_id and
            response.status == :pending
      )

    dynamic(
      [improvement_candidates: c],
      (not is_nil(c.episode_id) and not exists(running_work)) or
        (not is_nil(c.input_id) and not exists(pending_replies))
    )
  end

  # A run of the parent query's candidate still out at Coop.
  defp outstanding_run do
    AnalysisRun.Query.all()
    |> AnalysisRun.Query.unstopped()
    |> where(
      [improvement_analysis_runs: r],
      r.candidate_id == parent_as(:improvement_candidates).id
    )
  end

  @doc """
  When analysis has something to claim by the clock alone after `since`, as
  `[quiet_due, retry_due, lease_due]`: a candidate's quiet time of `quiet`
  seconds ends (only with `enabled?`), its retry or hold ends (with analysis
  off, only for a run still out at Coop), or the lease of a worker that
  stopped renewing it runs out.
  """
  def select_next_due_after(since, quiet, enabled?) do
    from(c in all(),
      where: c.analysis in [:pending, :running],
      select: [
        filter(
          min(datetime_add(c.last_signal_at, ^quiet, "second")),
          ^enabled? and c.analysis == :pending and is_nil(c.forgotten_at) and
            c.status != :dismissed and
            datetime_add(c.last_signal_at, ^quiet, "second") > ^since
        ),
        filter(
          min(c.next_attempt_at),
          c.analysis == :pending and c.next_attempt_at > ^since and
            (^enabled? or exists(outstanding_run()))
        ),
        filter(
          min(c.lease_expires_at),
          c.analysis == :running and c.lease_expires_at > ^since
        )
      ]
    )
  end

  @doc "Accepted cases still kept with their frozen evidence, oldest decision first."
  def exportable_cases do
    from(c in all(),
      where: c.status == :accepted and is_nil(c.forgotten_at) and not is_nil(c.case_evidence),
      order_by: [asc: c.decided_at, asc: c.id]
    )
  end

  @doc "Still to analyze, and not dismissed."
  def awaiting_analysis(queryable) do
    where(
      queryable,
      [improvement_candidates: c],
      c.analysis in [:pending, :running] and c.status != :dismissed
    )
  end

  def by_category(queryable, category),
    do: where(queryable, [improvement_candidates: c], c.category == ^category)

  def select_statuses(queryable), do: select(queryable, [improvement_candidates: c], c.status)

  @doc "How many candidates each decision holds, as `{status, count}`."
  def count_by_status(queryable) do
    queryable
    |> group_by([improvement_candidates: c], c.status)
    |> select([improvement_candidates: c], {c.status, count()})
  end

  @doc """
  The order What to fix lists candidates in: newest day first, and within a
  day the surest diagnosis first, then the newest; the id breaks ties so no
  row repeats or goes missing between pages.
  """
  def review_order do
    [
      desc: dynamic([improvement_candidates: c], fragment("date(?)", c.last_signal_at)),
      desc:
        dynamic(
          [improvement_candidates: c],
          fragment(
            "CASE ? WHEN 'high' THEN 3 WHEN 'medium' THEN 2 WHEN 'low' THEN 1 ELSE 0 END",
            c.confidence
          )
        ),
      desc: dynamic([improvement_candidates: c], c.last_signal_at),
      desc: dynamic([improvement_candidates: c], c.id)
    ]
  end

  def count_by_category(queryable) do
    queryable
    |> where([improvement_candidates: c], not is_nil(c.category))
    |> group_by([improvement_candidates: c], c.category)
    |> select([improvement_candidates: c], {c.category, count()})
  end

  def quoting_messages(keys) do
    where(
      all(),
      [improvement_candidates: c],
      fragment("? && ?::text[]", c.message_keys, ^keys)
    )
  end

  @doc "Candidates about conversation `conversation_ref` or quoting it."
  def by_conversation_ref(conversation_ref) do
    where(
      all(),
      [improvement_candidates: c],
      c.conversation_ref == ^conversation_ref or
        fragment("? @> ARRAY[?]::text[]", c.conversation_refs, ^conversation_ref)
    )
  end

  @doc """
  What a second signal on a request does to its candidate: one more signal,
  its reason among the others, and the first and last signal times widened.
  """
  def merge_signal do
    from(c in Candidate,
      update: [
        set: [
          reasons:
            fragment(
              "ARRAY(SELECT DISTINCT reason FROM unnest(? || EXCLUDED.reasons) AS reason ORDER BY reason)",
              c.reasons
            ),
          first_signal_at: fragment("LEAST(?, EXCLUDED.first_signal_at)", c.first_signal_at),
          last_signal_at: fragment("GREATEST(?, EXCLUDED.last_signal_at)", c.last_signal_at),
          updated_at: fragment("EXCLUDED.updated_at")
        ],
        inc: [signal_count: 1]
      ]
    )
  end

  def select_ids(queryable), do: select(queryable, [improvement_candidates: c], c.id)
  def lock_for_update(queryable), do: lock(queryable, "FOR UPDATE")
end
