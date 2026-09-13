defmodule Ryker.State.ResponseChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Ryker.State.Response

  @fields [
    :actor_ref,
    :choice,
    :choice_index,
    :id,
    :inbox_entry_id,
    :occurred_at,
    :record_id,
    :response_ref
  ]

  @spec insert(map()) :: Ecto.Changeset.t()
  def insert(attributes) do
    %Response{}
    |> cast(attributes, @fields)
    |> validate_required(@fields -- [:choice, :choice_index])
    |> validate_length(:response_ref, min: 1, max: 1_024)
    |> validate_length(:actor_ref, min: 1, max: 1_024)
    |> validate_number(:choice_index, greater_than_or_equal_to: 0, less_than_or_equal_to: 9)
    |> validate_length(:choice, min: 1, max: 240)
    |> validate_choice_pair()
    |> unique_constraint(:record_id)
    |> unique_constraint(:inbox_entry_id)
    |> unique_constraint(:response_ref)
    |> foreign_key_constraint(:record_id)
    |> foreign_key_constraint(:inbox_entry_id)
    |> check_constraint(:choice, name: :episode_state_record_response_valid)
  end

  defp validate_choice_pair(changeset) do
    if is_nil(get_field(changeset, :choice_index)) == is_nil(get_field(changeset, :choice)),
      do: changeset,
      else: add_error(changeset, :choice, "must accompany its choice index")
  end
end
