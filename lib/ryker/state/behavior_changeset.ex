defmodule Ryker.State.BehaviorChangeset do
  @moduledoc false

  import Ecto.Changeset

  alias Ryker.State.Behavior

  @fields [
    :confirmed_at,
    :confirmed_by_actor_ref,
    :confirmation_ref,
    :cutover_item_id,
    :expires_at,
    :edited_at,
    :edited_by_actor_ref,
    :edit_review_ref,
    :id,
    :identity_key,
    :kind,
    :last_used_at,
    :last_reviewed_at,
    :offer_record_id,
    :payload,
    :ref,
    :revision,
    :scope_kind,
    :scope_ref,
    :source_conversation_ref,
    :source_message_ref,
    :source_thread_ref,
    :source_transport,
    :status,
    :use_count,
    :workspace_ref
  ]

  @insert_required @fields --
                     [
                       :cutover_item_id,
                       :expires_at,
                       :edited_at,
                       :edited_by_actor_ref,
                       :edit_review_ref,
                       :last_reviewed_at,
                       :last_used_at,
                       :source_thread_ref,
                       :use_count
                     ]

  def insert(attributes) do
    %Behavior{}
    |> cast(attributes, @fields)
    |> validate_required(@insert_required)
    |> validate()
  end

  defp validate(changeset) do
    changeset
    |> unique_constraint(:ref)
    |> unique_constraint(:offer_record_id)
    |> unique_constraint(:cutover_item_id)
    |> unique_constraint(:identity_key, name: :operator_behaviors_active_identity)
    |> foreign_key_constraint(:offer_record_id)
    |> foreign_key_constraint(:cutover_item_id)
    |> check_constraint(:offer_record_id, name: :operator_behavior_provenance_valid)
    |> check_constraint(:kind, name: :operator_behavior_valid)
    |> check_constraint(:edited_at, name: :operator_behavior_edit_provenance_valid)
    |> check_constraint(:revision, name: :operator_behavior_revision_valid)
  end

  def update(%Behavior{} = behavior, attributes) do
    behavior
    |> cast(attributes, @fields)
    |> unique_constraint(:identity_key, name: :operator_behaviors_active_identity)
    |> check_constraint(:kind, name: :operator_behavior_valid)
    |> check_constraint(:edited_at, name: :operator_behavior_edit_provenance_valid)
    |> check_constraint(:revision, name: :operator_behavior_revision_valid)
  end
end
