defmodule Responder.Settings.PolicyBinding do
  @moduledoc """
  A reviewed binding from one execution purpose and scope to an exact worker policy.

  The digest and authority digest are execution evidence pinned from a verified
  worker advertisement or an explicit import; a browser never types them.
  """
  use Ecto.Schema
  import Ecto.Changeset
  alias Responder.Settings.Validation

  @installation_purposes [
    :admission,
    :learning,
    :incident,
    :schedule_read_only,
    :schedule_governed
  ]
  @context_purposes [:conversational, :standard, :deep, :contributor]
  @repository_purposes @context_purposes ++ [:schedule]
  @primary_key {:id, :binary_id, autogenerate: false}
  @fields ~w(id purpose scope_kind scope_ref policy_name policy_digest authority_digest verified_by verified_worker_ref)a

  schema "policy_bindings" do
    field(:purpose, Ecto.Enum, values: @installation_purposes ++ @repository_purposes)
    field(:scope_kind, Ecto.Enum, values: [:installation, :repository, :context])
    field(:scope_ref, :string, default: "")
    field(:policy_name, :string)
    field(:policy_digest, :string)
    field(:authority_digest, :string)
    field(:verified_by, Ecto.Enum, values: [:worker, :import])
    field(:verified_worker_ref, :string)
    timestamps(type: :utc_datetime_usec)
  end

  def installation_purposes, do: @installation_purposes
  def repository_purposes, do: @repository_purposes
  def context_purposes, do: @context_purposes
  def fields, do: @fields
  def new(_snapshot), do: %__MODULE__{id: Ecto.UUID.generate()}

  def find(snapshot, :id, id) when is_binary(id),
    do: Enum.find(snapshot.policy_bindings, &(&1.id == id))

  def find(_snapshot, :id, _id), do: nil

  def changeset(current, attributes, snapshot) do
    changeset =
      current
      |> cast(attributes, @fields -- [:id], empty_values: [])
      |> validate_required([
        :purpose,
        :scope_kind,
        :scope_ref,
        :policy_name,
        :policy_digest,
        :verified_by
      ])
      |> validate_length(:policy_name, min: 1, max: 256)
      |> validate_format(:policy_digest, Validation.hex64_pattern())
      |> validate_format(:authority_digest, Validation.hex64_pattern())
      |> validate_length(:verified_worker_ref, min: 1, max: 256)
      |> validate_scope(snapshot)

    duplicate =
      Enum.any?(snapshot.policy_bindings, fn binding ->
        binding.id != current.id and binding.purpose == get_field(changeset, :purpose) and
          binding.scope_kind == get_field(changeset, :scope_kind) and
          binding.scope_ref == get_field(changeset, :scope_ref)
      end)

    if duplicate,
      do:
        add_error(changeset, :purpose, "is already bound for this scope",
          validation: :already_bound
        ),
      else: changeset
  end

  defp validate_scope(changeset, snapshot) do
    purpose = get_field(changeset, :purpose)
    scope_kind = get_field(changeset, :scope_kind)
    scope_ref = get_field(changeset, :scope_ref)

    case {purpose, scope_kind} do
      {purpose, :installation} when purpose in @installation_purposes ->
        if scope_ref == "",
          do: changeset,
          else: add_error(changeset, :scope_ref, "must be empty", validation: :scope)

      {purpose, :repository} when purpose in @repository_purposes ->
        Validation.validate_known(
          changeset,
          :scope_ref,
          Enum.map(snapshot.repositories, & &1.ref),
          :unknown_repository
        )

      {purpose, :context} when purpose in @context_purposes ->
        Validation.validate_known(
          changeset,
          :scope_ref,
          Enum.map(snapshot.contexts, & &1.ref),
          :unknown_context
        )

      _mismatch ->
        add_error(changeset, :scope_kind, "does not fit this purpose", validation: :scope)
    end
  end

  def deletable(_binding, _snapshot), do: :ok
end
