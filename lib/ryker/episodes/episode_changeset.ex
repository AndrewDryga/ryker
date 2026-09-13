defmodule Ryker.Episodes.EpisodeChangeset do
  @moduledoc false

  import Ecto.Changeset
  alias Ryker.Episodes.Episode

  @mutable_fields [
    :state,
    :owner_kind,
    :owner_ref,
    :owner_deadline_at,
    :semantic_version,
    :next_sequence,
    :input_revisions,
    :active_input_refs,
    :queued_input_refs,
    :queued_input_order_keys
  ]

  @required_fields [
    :id,
    :key,
    :execution_mode,
    :state,
    :destination_transport,
    :destination_conversation_ref,
    :semantic_version,
    :next_sequence,
    :input_revisions,
    :active_input_refs,
    :queued_input_refs,
    :queued_input_order_keys
  ]

  @spec insert(Episode.t()) :: Ecto.Changeset.t()
  def insert(%Episode{} = episode) do
    episode
    |> change()
    |> validate()
  end

  @spec advance(Episode.t(), Episode.t()) :: Ecto.Changeset.t()
  def advance(%Episode{} = stored, %Episode{} = decided) do
    attrs = decided |> Map.from_struct() |> Map.take(@mutable_fields)

    stored
    |> cast(attrs, @mutable_fields)
    |> validate()
  end

  defp validate(changeset) do
    changeset
    |> validate_required(@required_fields)
    |> unique_constraint(:id, name: :episode_kernel_episodes_pkey)
    |> unique_constraint(:key)
    |> foreign_key_constraint(:linked_episode_id)
    |> check_constraint(:key, name: :episode_kernel_episode_key_not_empty)
    |> check_constraint(:execution_mode, name: :episode_kernel_execution_mode_valid)
    |> check_constraint(:destination_transport, name: :episode_kernel_destination_not_empty)
    |> check_constraint(:linked_episode_id, name: :episode_kernel_history_not_self)
    |> check_constraint(:semantic_version, name: :episode_kernel_versions_nonnegative)
    |> check_constraint(:state, name: :episode_kernel_owner_matches_state)
    |> check_constraint(:active_input_refs, name: :episode_kernel_inputs_match_owner)
  end
end
