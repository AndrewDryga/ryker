defmodule Ryker.Settings.Environment do
  @moduledoc """
  A named bundle of what work in it may use.

  Its repositories are a set: every session in the environment mounts all of
  them, the one its work changes as the working copy and every other one
  read-only under its own ref. Each repository is read and write, which a
  task may change, or read only, which work only reads (Andrew, 2026-09-27:
  "can we here limit read or read/write access per repo?"). Each piece of
  work chooses the read and write repository it changes; the default, the
  first, is the one it changes unless it picks another, so the default is
  always read and write. It may name one Emisar account. At most one
  environment is the default, which Chat and every conversation without its
  own setting use. Slack channels and webhook sources select an environment;
  GitHub events run in the environment
  `Ryker.Settings.environment_for_repository/2` names.

  The snapshot carries its repositories as
  `%EnvironmentRepository{repository_ref, position, access}` rows, the
  default first. A save names them as `Ryker.Settings.Environment.Changeset`
  says.
  """
  use Ecto.Schema
  alias Ryker.Settings.EnvironmentRepository

  @primary_key {:ref, :string, autogenerate: false}
  @ref ~r/\A[a-z0-9][a-z0-9-]{0,63}\z/

  @type t :: %__MODULE__{
          ref: String.t(),
          display_name: String.t(),
          description: String.t() | nil,
          emisar_connection_ref: String.t() | nil,
          is_default: boolean(),
          parallel_goal_limit: 1..3,
          repositories: [EnvironmentRepository.t()]
        }

  schema "environment_settings" do
    field(:display_name, :string)
    field(:description, :string)
    field(:emisar_connection_ref, :string)
    field(:is_default, :boolean, default: false)
    field(:parallel_goal_limit, :integer, default: 3)
    # The repositories a save writes, the default first: [{ref, access}].
    field(:repository_rows, {:array, :any}, virtual: true)

    has_many(:repositories, EnvironmentRepository,
      foreign_key: :environment_ref,
      references: :ref,
      preload_order: [asc: :position]
    )

    timestamps(type: :utc_datetime_usec)
  end

  def ref_pattern, do: @ref

  @doc "The environment's repository refs, the default first."
  @spec repository_refs(t()) :: [String.t()]
  def repository_refs(%__MODULE__{repositories: repositories}),
    do: Enum.map(repositories, & &1.repository_ref)

  @doc "The repositories a task in the environment may change, the default first."
  @spec writable_refs(t()) :: [String.t()]
  def writable_refs(%__MODULE__{repositories: repositories}),
    do: for(%{access: :read_write} = row <- repositories, do: row.repository_ref)

  @doc "The repositories work in the environment only reads."
  @spec read_only_refs(t()) :: [String.t()]
  def read_only_refs(%__MODULE__{repositories: repositories}),
    do: for(%{access: :read_only} = row <- repositories, do: row.repository_ref)
end
