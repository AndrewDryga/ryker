defmodule Ryker.ControlPlane.ActionRefusal do
  @moduledoc """
  Why a confirmed action did not go through, in words, for the page a person
  lands on instead of the result. Every refusal used to read "Action is no
  longer available" on a bare text page with no way back, even a schedule
  whose previous run was still going (manual testing, 2026-09-26).
  """

  @spec explain(term()) :: String.t()
  def explain(:schedule_occurrence_active),
    do: "A run of this schedule is still going. Start another when it finishes."

  def explain(reason) when reason in [:schedule_terminal, :schedule_expired],
    do: "This schedule has ended, so it can no longer run or change."

  def explain(:schedule_revision_stale),
    do: "This schedule changed after you opened the page. Go back to see it now, then try again."

  def explain(:schedule_not_found), do: "This schedule no longer exists."

  def explain(:schedule_policy_unavailable),
    do:
      "Scheduled work cannot start because no worker is set up to run it. " <>
        "Settings › Advanced shows how to add one."

  def explain(:improvement_evidence_unavailable),
    do:
      "The person's messages were deleted or have expired, so there is nothing to keep as an eval case. You can still dismiss it."

  def explain(_reason),
    do: "Ryker did not do this. The page may be out of date: go back, reload it, and try again."
end
