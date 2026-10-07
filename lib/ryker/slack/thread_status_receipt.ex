defmodule Ryker.Slack.ThreadStatusReceipt do
  @moduledoc false
  use Ryker, :schema

  schema "slack_thread_status_receipts" do
    field(:workspace_ref, :string)
    field(:channel_ref, :string)
    field(:thread_ref, :string)
    field(:generation, :integer)
    field(:lease_ref, :binary_id)
    field(:origin_kind, :string)
    field(:origin_id, :binary_id)
    field(:phase, :string)
    field(:text, :string)
    field(:error, :string)
    field(:acknowledged_at, :utc_datetime_usec)
    timestamps(updated_at: false)
  end
end
