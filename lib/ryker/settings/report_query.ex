defmodule Ryker.Settings.ReportQuery do
  @moduledoc "Where and when the weekly report goes, for every read of `report_settings`."
  import Ecto.Query
  alias Ryker.Settings.Report

  def all, do: from(settings in Report, as: :report_settings)
  def select_timezone(queryable \\ all()), do: select(queryable, [report_settings: r], r.timezone)
end
