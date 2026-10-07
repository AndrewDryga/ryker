defmodule Ryker.Delivery.PlatformActionChangeset do
  @moduledoc """
  How a platform action is recorded and delivered
  (`Ryker.Delivery.PlatformAction`), through the lease custody of
  `Ryker.Delivery.LeaseChangeset`.
  """
  import Ecto.Changeset
  alias Ryker.Delivery.{LeaseChangeset, PlatformAction}

  @fields [
    :action_ref,
    :attempt_count,
    :conversation_ref,
    :document,
    :episode_id,
    :host_slot,
    :id,
    :intent_fingerprint,
    :kind,
    :retry_generation,
    :source_item_ref,
    :status,
    :thread_ref,
    :tool,
    :transport,
    :turn_id
  ]
  # Not every action answers a message, and not every one posts in a thread.
  @required @fields -- [:source_item_ref, :thread_ref]

  @doc "An action a Work turn asked for, pending its first attempt."
  def insert(attributes) do
    %PlatformAction{}
    |> cast(attributes, @fields)
    |> validate_required(@required)
    |> action_constraints()
  end

  @doc "See `Ryker.Delivery.LeaseChangeset.claim/5`."
  def claim(%PlatformAction{} = action, at, lease_seconds, owner, lease_ref) do
    action
    |> LeaseChangeset.claim(at, lease_seconds, owner, lease_ref)
    |> action_constraints()
  end

  @doc "See `Ryker.Delivery.LeaseChangeset.renew/2`."
  def renew(%PlatformAction{} = action, expires_at),
    do: action |> LeaseChangeset.renew(expires_at) |> action_constraints()

  @doc "See `Ryker.Delivery.LeaseChangeset.defer/4`."
  def defer(%PlatformAction{} = action, next_attempt_at, error_code, error_detail) do
    action
    |> LeaseChangeset.defer(next_attempt_at, error_code, error_detail)
    |> action_constraints()
  end

  @doc "See `Ryker.Delivery.LeaseChangeset.block/3`."
  def block(%PlatformAction{} = action, error_code, error_detail),
    do: action |> LeaseChangeset.block(error_code, error_detail) |> action_constraints()

  @doc "See `Ryker.Delivery.LeaseChangeset.retry/1`."
  def retry(%PlatformAction{} = action),
    do: action |> LeaseChangeset.retry() |> action_constraints()

  @doc "See `Ryker.Delivery.LeaseChangeset.confirm/4`."
  def confirm(%PlatformAction{} = action, at, receipt, fingerprint),
    do: action |> LeaseChangeset.confirm(at, receipt, fingerprint) |> action_constraints()

  defp action_constraints(changeset) do
    changeset
    |> check_constraint(:action_ref, name: :platform_actions_identity_valid)
    |> check_constraint(:document, name: :platform_actions_document_valid)
    |> check_constraint(:status, name: :platform_actions_custody_valid)
    |> unique_constraint(:action_ref)
    |> unique_constraint([:turn_id, :host_slot])
    |> foreign_key_constraint(:episode_id)
    |> foreign_key_constraint(:turn_id)
  end
end
