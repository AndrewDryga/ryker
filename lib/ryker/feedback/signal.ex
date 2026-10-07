defmodule Ryker.Feedback.Signal do
  @moduledoc """
  One signal about one of Ryker's answers (`answer_feedback`), kept with the
  request the answer belongs to: its episode, or the message routing answered
  by itself. `Ryker.Feedback` writes and reads these.

  - `kind` is what happened: `reaction_added`, `reaction_removed`,
    `message_edited`, `message_deleted`, `asked_again`, `sentiment` (how
    routing read the person's next message) or `reviewed` (a person rated
    how a finished request went).
  - `value` is the emoji name of a reaction, the feeling of a sentiment
    (satisfied, neutral, frustrated or angry), a rating (good or
    needs_work), and nil for the rest.
  - `note` is a sentiment's reason or a rating's note, when there is one.
  - `category` is how the Feedback page groups it, frustrated first; it is
    written once, when the signal is recorded.
  - `actor_ref` is who gave it, as its `source` names people (a Slack user,
    or the person using this console), and `source_ref` the event it came
    from: one event gives at most one signal of a kind.
  - `message_ref` is, for a reaction, the one message of Ryker's it was on,
    as its platform names it: a quick reply can be several messages, and a
    request holds its updates beside its replies.
  """

  use Ecto.Schema
  alias Ryker.Episodes.Episode
  alias Ryker.Ingress.Inbox.Entry

  @kinds [
    :reaction_added,
    :reaction_removed,
    :message_edited,
    :message_deleted,
    :asked_again,
    :sentiment,
    :reviewed
  ]
  @categories [:frustrated, :asked_again, :edited, :neutral, :satisfied]

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "answer_feedback" do
    field(:kind, Ecto.Enum, values: @kinds)
    field(:value, :string)
    field(:note, :string)
    field(:category, Ecto.Enum, values: @categories)
    field(:actor_ref, :string)
    field(:source, :string)
    field(:source_ref, :string)
    field(:occurred_at, :utc_datetime_usec)
    field(:message_ref, :string)
    belongs_to(:episode, Episode)
    belongs_to(:input, Entry)
    # When Ryker recorded it, by the database's clock; retention ages it.
    field(:inserted_at, :utc_datetime_usec, read_after_writes: true)
  end

  @type t :: %__MODULE__{}

  @doc "The kinds of signal, in the order the code lists them."
  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @doc "The Feedback page's categories, frustrated first."
  @spec categories() :: [atom()]
  def categories, do: @categories
end
