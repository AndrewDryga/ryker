defmodule Ryker.Settings.Report do
  @moduledoc """
  Whether the weekly report posts, in which Slack channel, and on which day
  of the week at which local time in which zone (`Ryker.WeeklyReport`). Off
  until a person turns it on.
  """
  use Ryker, :schema

  @primary_key {:id, :string, autogenerate: false}

  schema "report_settings" do
    field(:weekly_self_report_enabled, :boolean, default: false)
    field(:channel_ref, :string)
    field(:weekday, :integer, default: 1)
    field(:local_time, :time, default: ~T[09:00:00])
    field(:timezone, :string, default: "Etc/UTC")
    # When a person last changed any of the above. The report never posts a
    # send time that passed before then.
    field(:saved_at, :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
