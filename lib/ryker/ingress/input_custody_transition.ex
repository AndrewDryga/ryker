defmodule Ryker.Ingress.InputCustodyTransition do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "input_custody_transitions" do
    belongs_to(:input, Ryker.Ingress.Inbox.Entry)
    field(:sequence, :integer)

    field(:kind, Ecto.Enum,
      values: [
        :saved,
        :waiting_predecessor,
        :claimed,
        :reclaimed,
        :retry_scheduled,
        :blocked,
        :rearmed,
        :superseded
      ]
    )

    field(:occurred_at, :utc_datetime_usec)
    field(:generation, :integer)
    field(:attempt, :integer)
    belongs_to(:predecessor_input, Ryker.Ingress.Inbox.Entry)
    belongs_to(:superseding_input, Ryker.Ingress.Inbox.Entry)
    field(:owner_ref, :string)
    field(:eligible_at, :utc_datetime_usec)
    field(:error_code, :string)
    field(:detail, :string)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}
end
