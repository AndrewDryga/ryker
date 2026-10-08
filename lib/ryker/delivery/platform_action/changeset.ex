defmodule Ryker.Delivery.PlatformAction.Changeset do
  @moduledoc """
  How a platform action is recorded and delivered
  (`Ryker.Delivery.PlatformAction`), through the lease custody of
  `Ryker.Lease.Changeset`.
  """
  use Ryker, :changeset
  alias Ryker.Delivery.PlatformAction
  alias Ryker.Lease

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

  @doc "See `Ryker.Lease.Changeset.claim/5`."
  def claim(%PlatformAction{} = action, at, lease_seconds, owner, lease_ref) do
    action
    |> Lease.Changeset.claim(at, lease_seconds, owner, lease_ref)
    |> action_constraints()
  end

  @doc "See `Ryker.Lease.Changeset.renew/2`."
  def renew(%PlatformAction{} = action, expires_at),
    do: action |> Lease.Changeset.renew(expires_at) |> action_constraints()

  @doc "See `Ryker.Lease.Changeset.defer/4`."
  def defer(%PlatformAction{} = action, next_attempt_at, error_code, error_detail) do
    action
    |> Lease.Changeset.defer(next_attempt_at, error_code, error_detail)
    |> action_constraints()
  end

  @doc "See `Ryker.Lease.Changeset.block/3`."
  def block(%PlatformAction{} = action, error_code, error_detail),
    do: action |> Lease.Changeset.block(error_code, error_detail) |> action_constraints()

  @doc "See `Ryker.Lease.Changeset.retry/1`."
  def retry(%PlatformAction{} = action),
    do: action |> Lease.Changeset.retry() |> action_constraints()

  @doc "See `Ryker.Lease.Changeset.confirm/4`."
  def confirm(%PlatformAction{} = action, at, receipt, fingerprint),
    do: action |> Lease.Changeset.confirm(at, receipt, fingerprint) |> action_constraints()

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
