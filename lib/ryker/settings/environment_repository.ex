defmodule Ryker.Settings.EnvironmentRepository do
  @moduledoc """
  One repository of an environment: whether work there may change it, and
  whether it is the default.

  `access` is `:read_write` when a task in the environment may change the
  repository and `:read_only` when work only reads it (Andrew, 2026-09-27:
  "can we here limit read or read/write access per repo?"). Position 0 is the
  default repository, the one a task changes unless it picks another, so it
  is always read and write; the positions after it carry no meaning. Every
  session in the environment mounts all of its repositories: the one its work
  changes as the working copy and each other one read-only under its own ref.
  A read-only repository is only ever mounted that way.
  """
  use Ecto.Schema

  @primary_key false
  @accesses [:read_only, :read_write]

  @type access :: :read_only | :read_write

  @type t :: %__MODULE__{
          environment_ref: String.t(),
          repository_ref: String.t(),
          position: non_neg_integer(),
          access: access()
        }

  schema "environment_repository_settings" do
    field(:environment_ref, :string, primary_key: true)
    field(:repository_ref, :string, primary_key: true)
    field(:position, :integer)
    field(:access, Ecto.Enum, values: @accesses)
  end

  @doc "The accesses a repository of an environment may have."
  @spec accesses() :: [access()]
  def accesses, do: @accesses
end
