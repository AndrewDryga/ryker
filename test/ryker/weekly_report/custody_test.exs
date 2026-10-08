defmodule Ryker.WeeklyReport.CustodyTest do
  # Any refusal that named the week read as the week's report already being
  # saved, the database's check on a report's own dates and names included, so
  # the scheduler waited for a report it never saved (2026-10-04 review).
  use Ryker.DataCase, async: true
  alias Ryker.WeeklyReport.{Custody, Report}

  @report %{
    conversation_ref: "slack:T123:C456",
    due_at: ~U[2026-10-12 09:00:00.000000Z],
    message: "The week in Ryker.",
    period_start: ~U[2026-10-05 09:00:00.000000Z],
    timezone: "Etc/UTC",
    week: ~D[2026-10-12]
  }

  # The delivery pool wakes on a queued report, and Failures redraws on one
  # that is blocked. Until 2026-10-08 no test held a report to announcing
  # itself.
  test "a queued report reaches the delivery pool and the pages that show it" do
    :ok = Custody.subscribe_reports()
    assert {:ok, %Report{id: id}} = Custody.enqueue(@report)
    assert_receive {:weekly_report_updated, ^id}
  end

  test "only the week's report saved before reads as already queued" do
    assert {:ok, %Report{week: ~D[2026-10-12]}} = Custody.enqueue(@report)
    assert Custody.enqueue(@report) == {:ok, :already_queued}

    # A period that starts after the report is due is refused, not queued.
    refused = %{@report | week: ~D[2026-10-19], period_start: ~U[2026-10-20 09:00:00.000000Z]}

    assert {:error, {:weekly_report_persistence_failed, :enqueue, _errors}} =
             Custody.enqueue(refused)
  end
end
