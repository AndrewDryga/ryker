defmodule Ryker.BrowserTests.Report.Query do
  @moduledoc false
  use Ryker, :query
  alias Ryker.BrowserTests.Report

  def all, do: from(reports in Report, as: :browser_test_reports)

  def by_turn_id(queryable \\ all(), id),
    do: where(queryable, [browser_test_reports: r], r.turn_id == ^id)

  def by_turn_ids(queryable \\ all(), ids),
    do: where(queryable, [browser_test_reports: r], r.turn_id in ^ids)

  def chronological(queryable),
    do: order_by(queryable, [browser_test_reports: r], asc: r.inserted_at, asc: r.id)
end
