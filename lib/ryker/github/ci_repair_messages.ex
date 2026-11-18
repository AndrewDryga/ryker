defmodule Ryker.GitHub.CIRepairMessages do
  @moduledoc "One PR comment explains the automatic repair and its bounded outcome."
  alias Ryker.Delivery

  def request(projected) do
    repair = projected.repair

    Delivery.Request.new(%{
      ref: "github-ci-repair:#{repair.id}",
      kind: :message,
      transport: "github",
      conversation_ref: "github:#{repair.binding_ref}:repository:#{repair.repository_id}",
      thread_ref: "github:#{repair.binding_ref}:pull:#{repair.number}",
      source_item_ref: nil,
      document: %{
        "message" =>
          "**Automatic CI repair**\n\n" <>
            status(repair.status) <>
            "\n\nRepair rounds used: #{repair.rounds} of 2. Add the label `ryker:no-ci-fix` to stop automatic changes. Explicit requests remain available."
      },
      frozen_at: repair.inserted_at
    })
  end

  defp status("running"), do: "Reading failed checks and testing a focused fix on this PR."

  defp status("published") do
    "Published a tested fix to this PR. CI has not been confirmed green yet. See the repair report in this discussion."
  end

  defp status("passing"), do: "CI is passing. This failure episode is closed."

  defp status("publication_needs_attention") do
    "The fix was pushed, but the PR changed or could not be verified afterward. Automatic repair has stopped. Review the publication report before requesting more work."
  end

  defp status("checks_passing"),
    do: "CI is now passing. Stopping the unneeded repair and retaining its work."

  defp status("waiting_for_ci"), do: "Waiting for the current commit's checks."

  defp status("skipped") do
    "Automatic changes are disabled by ryker:no-ci-fix. Any active repair is stopping; its work is retained. Remove the label to check the current CI once."
  end

  defp status("disabled") do
    "Automatic changes are disabled for this repository. Any active repair is stopping; its work is retained."
  end

  defp status("limit_reached") do
    "Stopped after two repair rounds while CI still fails. Review the repair reports and ask explicitly if further work is needed."
  end

  defp status("head_changed"),
    do: "The PR head changed. Stopping the old repair so it cannot overwrite newer work."

  defp status("stopping"),
    do: "Waiting for the earlier repair to stop safely. No further automatic push is authorized."

  defp status("fork"), do: "Automatic repair cannot write to a fork PR."
  defp status("closed"), do: "This PR is closed. Automatic repair has stopped."
  defp status("not_owned"), do: "This repository only repairs Ryker's PRs automatically."
  defp status("stale_event"), do: "The check event names an older commit. No repair was started."

  defp status("no_change") do
    "This repair ended without a published fix. See its report for the reason; no duplicate attempt will start for the same commit."
  end

  defp status(_unavailable),
    do: "Automatic repair is unavailable for this PR. No new changes are authorized."
end
