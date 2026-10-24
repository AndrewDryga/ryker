defmodule Ryker.Emisar.ApprovalMessage do
  @moduledoc "The separate, host-routed review message of one asking Work turn."
  use Ryker, :schema

  schema "emisar_approval_messages" do
    belongs_to(:episode, Ryker.Episodes.Episode)
    belongs_to(:turn, Ryker.Work.Turn)
    field(:connection_ref, :string)
    field(:ref, :string)
    field(:transport, :string)
    field(:conversation_ref, :string)
    field(:thread_ref, :string)
    field(:external_receipt, Ryker.CanonicalJSON.Type)
    field(:card_fingerprint, :string)
    field(:checked_at, :utc_datetime_usec)
    field(:generation, :integer, default: 1)
    field(:status, Ecto.Enum, values: [:active, :blocked], default: :active)
    field(:attempt_count, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:lease_ref, :binary_id)
    field(:lease_owner, :string)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:last_error_code, :string)
    field(:last_error_detail, :string)
    timestamps()
  end

  @type t :: %__MODULE__{}
end
