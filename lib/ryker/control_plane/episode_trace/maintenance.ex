defmodule Ryker.ControlPlane.EpisodeTrace.Maintenance do
  @moduledoc """
  "Cleanup": what happened afterwards to the worker session and the working
  copy, at its own time. Closing is not removing, a kept workspace is
  not a failure, and a local session that never bound a remote one had nothing
  to delete.
  """

  import Ryker.ControlPlane.EpisodeTrace.Step

  alias Ryker.Work.Session

  @doc "Session close and workspace cleanup, each at the time it happened."
  def steps(sessions) do
    sessions
    |> Enum.filter(&(&1.cleanup_status != :active))
    |> Enum.flat_map(fn session ->
      closed =
        if session.closed_at do
          [
            step("maintenance-#{session.id}-closed", :maintenance, session.closed_at, %{
              actor: "Ryker",
              stage: "Maintenance",
              state: "session closed",
              title: "Worker session closed",
              summary: cleanup_repository(session),
              tone: nil,
              details:
                compact_details([
                  {"Repository", session.repository_ref},
                  {"Cleanup eligible after", session.discard_after},
                  {"Remote session", session.coop_session_id, identifier: true}
                ])
            })
          ]
        else
          []
        end

      closed ++ cleanup_outcome_step(session)
    end)
  end

  defp cleanup_outcome_step(%Session{cleanup_status: :discarded} = session) do
    kind = get_in(session.cleanup_receipt || %{}, ["kind"])
    {title, summary} = cleanup_outcome(kind)

    [
      step("maintenance-#{session.id}-discarded", :maintenance, session.discarded_at, %{
        actor: "Ryker",
        stage: "Maintenance",
        state: String.downcase(title),
        title: title,
        summary: summary,
        tone: nil,
        details:
          compact_details([
            {"Repository", session.repository_ref},
            {"Receipt", kind},
            {"Remote session", session.coop_session_id, identifier: true}
          ])
      })
    ]
  end

  defp cleanup_outcome_step(%Session{cleanup_status: :retained} = session) do
    [
      step("maintenance-#{session.id}-retained", :maintenance, session.updated_at, %{
        actor: "Ryker",
        stage: "Maintenance",
        state: "working copy kept · current",
        title: "Working copy kept",
        summary: retained_reason(session.retained_reason),
        tone: nil,
        details:
          compact_details([
            {"Repository", session.repository_ref},
            {"Reason", session.retained_reason},
            {"Remote session", session.coop_session_id, identifier: true}
          ])
      })
    ]
  end

  defp cleanup_outcome_step(%Session{cleanup_status: :blocked} = session) do
    [
      step("maintenance-#{session.id}-blocked", :maintenance, session.updated_at, %{
        actor: "Ryker",
        stage: "Maintenance",
        state: "cleanup blocked · current",
        title: "Cleanup blocked",
        summary:
          "Cleanup stopped and needs attention. The delivered answer is unaffected." <>
            error_sentence(session.cleanup_last_error_code),
        tone: :warn,
        details:
          compact_details([
            {"Repository", session.repository_ref},
            {"Blocked from", session.cleanup_blocked_from},
            {"Attempts", session.cleanup_attempt_count},
            {"Next attempt", session.cleanup_next_attempt_at}
          ])
      })
    ]
  end

  defp cleanup_outcome_step(_session), do: []

  defp cleanup_repository(%Session{repository_ref: nil}),
    do: "The worker session was closed. No repository working copy was bound to it."

  defp cleanup_repository(%Session{repository_ref: repository}),
    do: "#{repository}'s worker session was closed. Closing it does not remove its working copy."

  # What the cleanup receipt proves, by the kind cleanup writes. Only
  # "discarded" is a removal this pass made.
  defp cleanup_outcome("never_bound"),
    do:
      {"Nothing to remove",
       "Ryker never learned a worker session for this request, so it had nothing to close or remove."}

  defp cleanup_outcome("already_discarded"),
    do:
      {"Working copy already gone",
       "The worker reported the working copy was already gone; Ryker saw that, it did not delete it."}

  defp cleanup_outcome("remote_absent"),
    do:
      {"Working copy already gone",
       "The worker no longer knew this session, so there was nothing left to close or remove."}

  defp cleanup_outcome("worker_removed"),
    do:
      {"Working copy left on a removed worker",
       "The worker holding it was removed from Ryker, so Ryker cannot reach it to close or remove it."}

  defp cleanup_outcome(_kind),
    do:
      {"Working copy removed",
       "The temporary working copy was removed. What this page shows about the work is unaffected."}

  defp retained_reason("dirty" <> _),
    do: "The working copy was kept: it still holds uncommitted changes."

  defp retained_reason("unmerged" <> _),
    do: "The working copy was kept: it still holds commits that were never published."

  defp retained_reason(nil), do: "The working copy was kept. No reason was recorded."
  defp retained_reason(reason), do: "The working copy was kept: " <> human(reason) <> "."
end
