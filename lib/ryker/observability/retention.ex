defmodule Ryker.Observability.Retention do
  @moduledoc """
  Workspace cleanup reported by reason, not only as a queue depth.

  Every retained byte must be explainable, so sessions are counted by cleanup
  status and the retained ones by why they are kept. An absent measurement
  stays absent: the report never substitutes zero for something no worker has
  reported.
  """

  import Ecto.Query
  alias Ryker.Observability.Reads
  alias Ryker.Retention.Custody, as: RetentionCustody
  alias Ryker.Work.Session

  @doc "Cleanup at the database clock reading `now`."
  @spec snapshot(DateTime.t()) :: {:ok, map()} | {:error, Reads.failure()}
  def snapshot(now) do
    eligible = RetentionCustody.eligible_query(now)

    retrying =
      from(session in Session,
        where: session.cleanup_status in [:close_pending, :plan_pending, :discard_pending],
        where: not is_nil(session.cleanup_next_attempt_at),
        where: session.cleanup_next_attempt_at > ^now
      )

    retained =
      from(session in Session,
        where: session.cleanup_status == :retained,
        group_by: session.retained_reason,
        select: {session.retained_reason, count(session.id)}
      )

    with {:ok, last_reclaimed} <-
           Reads.one(from(session in Session, select: max(session.discarded_at))),
         {:ok, blocked} <-
           Reads.count(from(session in Session, where: session.cleanup_status == :blocked)),
         {:ok, eligible_count} <- Reads.count(eligible),
         {:ok, oldest_eligible} <-
           Reads.read(fn -> RetentionCustody.oldest_eligible_at(eligible) end),
         {:ok, retained} <- Reads.all(retained),
         {:ok, retrying} <- Reads.count(retrying),
         {:ok, sessions} <- Reads.counts(Session, :cleanup_status) do
      {:ok,
       %{
         blocked: blocked,
         eligible: eligible_count,
         last_reclaimed_age_seconds: Reads.age_seconds(now, last_reclaimed),
         oldest_eligible_age_seconds: Reads.age_seconds(now, oldest_eligible),
         retained: Map.new(retained),
         retrying: retrying,
         sessions: sessions
       }}
    end
  end
end
