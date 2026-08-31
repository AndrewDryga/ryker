defmodule Responder.Slack.SourceAudit do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "slack_source_audits" do
    belongs_to(:episode, Responder.Episodes.Episode)
    belongs_to(:turn, Responder.Work.Turn)
    field(:workspace_ref, :string)
    field(:channel_ref, :string)
    field(:requester_ref, :string)
    field(:tool, Ecto.Enum, values: [:list_slack_channels, :search_slack, :read_slack_source])
    field(:capability, :string)
    field(:request_fingerprint, :string)
    field(:source_fingerprint, :string)
    field(:range_fingerprint, :string)
    field(:authorized, :boolean)
    field(:result_count, :integer)
    field(:complete, :boolean)
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end
end
