defmodule Ryker.WeeklyReport.Report do
  @moduledoc """
  One week's report (`weekly_reports`): the calendar `week` it was sent for
  (that week's Monday in `timezone`), the send time it fell due at
  (`due_at`), the week it covers (`period_start` up to `due_at`), the frozen
  words and the channel, and its delivery custody
  (`Ryker.WeeklyReport.Custody`). A row for a week means the week is sent or
  being sent; it is never written twice. A `preview` a person sent from
  Settings is a row too, and never the week's report.
  """
  use Ryker, :schema
  alias Ryker.CanonicalJSON

  schema "weekly_reports" do
    field(:week, :date)
    field(:preview, :boolean, default: false)
    field(:due_at, :utc_datetime_usec)
    field(:period_start, :utc_datetime_usec)
    field(:timezone, :string)
    field(:delivery_ref, :string)
    field(:transport, :string)
    field(:conversation_ref, :string)
    field(:document, CanonicalJSON.Type)
    field(:status, Ecto.Enum, values: [:pending, :blocked, :delivered], default: :pending)
    field(:attempt_count, :integer, default: 0)
    field(:retry_generation, :integer, default: 0)
    field(:lease_ref, :binary_id)
    field(:lease_owner, :string)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:last_error_code, :string)
    field(:last_error_detail, :string)
    field(:external_receipt, CanonicalJSON.Type)
    field(:external_receipt_fingerprint, :string)
    field(:delivered_at, :utc_datetime_usec)
    timestamps()
  end

  @type t :: %__MODULE__{}
end
