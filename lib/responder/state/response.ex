defmodule Responder.State.Response do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "episode_state_record_responses" do
    belongs_to(:record, Responder.State.Record)
    belongs_to(:inbox_entry, Responder.Ingress.Inbox.Entry)
    field(:response_ref, :string)
    field(:actor_ref, :string)
    field(:choice_index, :integer)
    field(:choice, :string)
    field(:occurred_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end
end
