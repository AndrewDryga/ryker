defmodule Ryker.Observability.Retention do
  @moduledoc """
  Workspace cleanup reported by reason, not only as a queue depth.

  Every retained byte must be explainable, so sessions are counted by cleanup
  status and the retained ones by why they are kept. An absent measurement
  stays absent: the report never substitutes zero for something no worker has
  reported.
  """

  alias Ryker.Observability.Reads
  alias Ryker.Retention.Cleanup
  alias Ryker.Work.Session

  @doc "Cleanup at the database clock reading `now`."
  @spec snapshot(DateTime.t()) :: {:ok, map()} | {:error, Reads.failure()}
  def snapshot(now) do
    eligible = Cleanup.Query.eligible(now)

    with {:ok, last_reclaimed} <- Reads.one(Session.Query.select_last_discarded()),
         {:ok, blocked} <- Reads.count(Session.Query.with_cleanup_status(:blocked)),
         {:ok, eligible_count} <- Reads.count(eligible),
         {:ok, oldest_eligible} <- Reads.one(Cleanup.Query.select_oldest_eligible_at(eligible)),
         {:ok, retained} <- Reads.all(Session.Query.retained_by_reason()),
         {:ok, retrying} <- Reads.count(Session.Query.cleanup_retrying_after(now)),
         {:ok, sessions} <- Reads.counts(Session.Query.all(), :cleanup_status) do
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
