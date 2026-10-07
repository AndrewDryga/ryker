defmodule Ryker.Observability.Retention do
  @moduledoc """
  Workspace cleanup reported by reason, not only as a queue depth.

  Every retained byte must be explainable, so sessions are counted by cleanup
  status and the retained ones by why they are kept. An absent measurement
  stays absent: the report never substitutes zero for something no worker has
  reported.
  """

  alias Ryker.Observability.Reads
  alias Ryker.Retention.CleanupQuery
  alias Ryker.Work.SessionQuery

  @doc "Cleanup at the database clock reading `now`."
  @spec snapshot(DateTime.t()) :: {:ok, map()} | {:error, Reads.failure()}
  def snapshot(now) do
    eligible = CleanupQuery.eligible(now)

    with {:ok, last_reclaimed} <- Reads.one(SessionQuery.select_last_discarded()),
         {:ok, blocked} <- Reads.count(SessionQuery.with_cleanup_status(:blocked)),
         {:ok, eligible_count} <- Reads.count(eligible),
         {:ok, oldest_eligible} <- Reads.one(CleanupQuery.select_oldest_eligible_at(eligible)),
         {:ok, retained} <- Reads.all(SessionQuery.retained_by_reason()),
         {:ok, retrying} <- Reads.count(SessionQuery.cleanup_retrying_after(now)),
         {:ok, sessions} <- Reads.counts(SessionQuery.all(), :cleanup_status) do
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
