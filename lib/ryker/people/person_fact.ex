defmodule Ryker.People.PersonFact do
  @moduledoc """
  One thing a person said about themselves (`person_facts`), the latest of its
  kind: `key` names the kind (`birthday`, `favourite-tv-show`) and `fact` says
  it in one short sentence. `Ryker.People` writes and reads these.

  - `person_ref` is the author of the message it came from, as its source
    names people (`slack:user:U…`, or the person using this console).
  - `source_input_id` and `source_message_ref` are that message's revision and
    the message itself across revisions; `said_at` is when it was said.
  - `conversation_ref` is where it was said, and `private` whether that place
    is a direct message or a private channel, where it stays.
  - A forgotten one has no `fact` and keeps the rest, so the message it came
    from never teaches it again.
  """
  use Ryker, :schema

  schema "person_facts" do
    field(:person_ref, :string)
    field(:key, :string)
    field(:fact, :string)
    field(:status, Ecto.Enum, values: [:kept, :forgotten])
    field(:source_input_id, :binary_id)
    field(:source_message_ref, :string)
    field(:conversation_ref, :string)
    field(:private, :boolean)
    field(:said_at, :utc_datetime_usec)
    field(:forgotten_at, :utc_datetime_usec)
    field(:inserted_at, :utc_datetime_usec, read_after_writes: true)
    field(:updated_at, :utc_datetime_usec, read_after_writes: true)
  end

  @type t :: %__MODULE__{}
end
