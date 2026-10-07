defmodule Ryker.Slack.ThreadStatusReceipt do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

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
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
