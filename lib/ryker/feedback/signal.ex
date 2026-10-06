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
  import Ecto.Changeset
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

  @fields [
    :id,
    :kind,
    :value,
    :note,
    :category,
    :actor_ref,
    :source,
    :source_ref,
    :occurred_at,
    :message_ref,
    :episode_id,
    :input_id
  ]

  @doc false
  @spec changeset(map()) :: Ecto.Changeset.t()
  def changeset(attributes) do
    %__MODULE__{}
    |> cast(attributes, @fields)
    |> validate_required([
      :id,
      :kind,
      :category,
      :actor_ref,
      :source,
      :source_ref,
      :occurred_at
    ])
    |> validate_length(:actor_ref, min: 1, max: 1_024)
    |> validate_length(:source_ref, min: 1, max: 1_024)
    |> validate_format(:source, ~r/\A[a-z0-9_.-]{1,64}\z/)
    |> validate_length(:note, min: 1, max: 2_048, count: :bytes)
    |> validate_length(:message_ref, min: 1, max: 1_024)
    |> validate_request()
    |> validate_value()
    |> validate_message()
    |> check_constraint(:kind, name: :answer_feedback_valid)
  end

  # Exactly one request: the episode the answer belongs to, or the message
  # routing answered by itself.
  defp validate_request(changeset) do
    case {get_field(changeset, :episode_id), get_field(changeset, :input_id)} do
      {episode_id, nil} when is_binary(episode_id) -> changeset
      {nil, input_id} when is_binary(input_id) -> changeset
      _neither_or_both -> add_error(changeset, :episode_id, "names no single request")
    end
  end

  @sentiments ~w(satisfied neutral frustrated angry)
  # A review is a rating.
  @reviews ~w(good needs_work)
  @emoji ~r/\A[a-z0-9_+\-]{1,100}\z/

  defp validate_value(changeset) do
    value = get_field(changeset, :value)

    valid? =
      case get_field(changeset, :kind) do
        :sentiment -> value in @sentiments
        :reviewed -> value in @reviews
        kind when kind in [:reaction_added, :reaction_removed] -> emoji?(value)
        _kind -> is_nil(value)
      end

    if valid?, do: changeset, else: add_error(changeset, :value, "does not fit its kind")
  end

  defp emoji?(value), do: is_binary(value) and Regex.match?(@emoji, value)

  # Only a reaction is on one message.
  defp validate_message(changeset) do
    case {get_field(changeset, :kind), get_field(changeset, :message_ref)} do
      {_kind, nil} -> changeset
      {kind, _ref} when kind in [:reaction_added, :reaction_removed] -> changeset
      _other -> add_error(changeset, :message_ref, "names a message only for a reaction")
    end
  end
end
