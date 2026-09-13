defmodule Ryker.Retention.OperatorAction do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "retention_operator_actions" do
    belongs_to(:session, Ryker.Work.Session)
    field(:action_ref, :string)
    field(:request_fingerprint, :string)
    field(:actor_ref, :string)
    field(:action, Ecto.Enum, values: [:rearm, :discard_unmerged])
    field(:previous_status, Ecto.Enum, values: [:blocked, :retained])
    field(:result_status, Ecto.Enum, values: [:close_pending, :plan_pending, :discard_pending])
    field(:previous_plan_fingerprint, :string)
    field(:occurred_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end
end
