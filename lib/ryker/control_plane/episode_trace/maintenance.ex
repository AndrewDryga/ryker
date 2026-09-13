defmodule Ryker.ControlPlane.EpisodeTrace.Maintenance do
  @moduledoc """
  "Maintenance": what happened to the temporary session and workspace
  afterwards, at its own time. Closing is not removing, a kept workspace is
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
              title: "Session closed",
              summary: cleanup_repository(session),
              tone: nil,
              details:
                compact_details([
                  {"Repository", session.repository_ref},
                  {"Cleanup eligible after", session.discard_after},
                  {"Session", session.coop_session_id || "No remote session was bound"}
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
    [
      step("maintenance-#{session.id}-discarded", :maintenance, session.discarded_at, %{
        actor: "Ryker",
        stage: "Maintenance",
        state: "workspace removed",
        title: "Workspace removed",
        summary: cleanup_receipt_summary(session),
        tone: nil,
        details:
          compact_details([
            {"Repository", session.repository_ref},
            {"Receipt", get_in(session.cleanup_receipt || %{}, ["outcome"])},
            {"Session", session.coop_session_id}
          ])
      })
    ]
  end

  defp cleanup_outcome_step(%Session{cleanup_status: :retained} = session) do
    [
      step("maintenance-#{session.id}-retained", :maintenance, session.updated_at, %{
        actor: "Ryker",
        stage: "Maintenance",
        state: "workspace kept",
        title: "Workspace kept",
        summary: retained_reason(session.retained_reason),
        tone: nil,
        details:
          compact_details([
            {"Repository", session.repository_ref},
            {"Reason", session.retained_reason},
            {"Session", session.coop_session_id}
          ])
      })
    ]
  end

  defp cleanup_outcome_step(%Session{cleanup_status: :blocked} = session) do
    [
      step("maintenance-#{session.id}-blocked", :maintenance, session.updated_at, %{
        actor: "Ryker",
        stage: "Maintenance",
        state: "cleanup blocked",
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
    do: "#{repository}'s worker session was closed. Closing is not removing its workspace."

  defp cleanup_receipt_summary(%Session{cleanup_receipt: %{"outcome" => "never_bound"}}),
    do: "No remote session was ever bound, so there was no remote workspace to delete."

  defp cleanup_receipt_summary(%Session{cleanup_receipt: %{"outcome" => "already_discarded"}}),
    do:
      "The worker reported the workspace was already gone; this pass observed that, it did not delete it."

  defp cleanup_receipt_summary(_session),
    do: "The temporary workspace was discarded. Retained inspection evidence is unaffected."

  defp retained_reason("dirty" <> _),
    do: "The workspace was kept: it still holds uncommitted changes."

  defp retained_reason("unmerged" <> _),
    do: "The workspace was kept: it still holds commits that were never published."

  defp retained_reason(nil), do: "The workspace was kept. No reason was recorded."
  defp retained_reason(reason), do: "The workspace was kept: " <> human(reason) <> "."
end
