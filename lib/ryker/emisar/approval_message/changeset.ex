defmodule Ryker.Emisar.ApprovalMessage.Changeset do
  @moduledoc false
  use Ryker, :changeset
  alias Ryker.Emisar.ApprovalMessage

  @identity ~w(episode_id turn_id connection_ref ref transport conversation_ref thread_ref)a
  @mutable ~w(external_receipt card_fingerprint checked_at generation status attempt_count next_attempt_at lease_ref lease_owner lease_expires_at last_error_code last_error_detail)a

  def insert(attributes) do
    %ApprovalMessage{}
    |> cast(attributes, @identity)
    |> validate_required(@identity -- [:thread_ref])
    |> message_constraints()
  end

  def update(%ApprovalMessage{} = message, attributes),
    do: message |> cast(attributes, @mutable) |> message_constraints()

  defp message_constraints(changeset) do
    changeset
    |> unique_constraint(:turn_id)
    |> unique_constraint(:ref)
    |> foreign_key_constraint(:episode_id)
    |> foreign_key_constraint(:turn_id)
    |> check_constraint(:ref, name: :emisar_approval_message_valid)
  end
end
