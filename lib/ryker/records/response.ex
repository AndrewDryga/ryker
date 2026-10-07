defmodule Ryker.Records.Response do
  @moduledoc false
  use Ryker, :schema

  schema "episode_state_record_responses" do
    belongs_to(:record, Ryker.Records.Record)
    belongs_to(:inbox_entry, Ryker.Ingress.Inbox.Entry)
    field(:response_ref, :string)
    field(:actor_ref, :string)
    field(:choice_index, :integer)
    field(:choice, :string)
    field(:occurred_at, :utc_datetime_usec)

    timestamps()
  end
end
