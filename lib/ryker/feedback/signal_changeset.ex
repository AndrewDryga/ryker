defmodule Ryker.Feedback.SignalChangeset do
  @moduledoc "The one write of a feedback signal (`Ryker.Feedback.Signal`)."
  import Ecto.Changeset
  alias Ryker.Feedback.Signal

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

  @doc "A signal to record, refused unless it names one request and its value fits its kind."
  @spec insert(map()) :: Ecto.Changeset.t()
  def insert(attributes) do
    %Signal{}
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
