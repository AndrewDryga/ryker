defmodule Ryker do
  @moduledoc """
  The roles of Ryker's data modules, as Emisar's `use Emisar, ...` gives them:
  `use Ryker, :schema` in a schema module, `:query` in its Query module and
  `:changeset` in its Changeset module, so each kind starts from the same
  imports and attributes (`Ryker.Checks.UseRykerRole`). A schema that differs
  states only the difference, such as a string `@primary_key`.
  """

  @doc false
  def schema do
    quote do
      use Ecto.Schema

      # UUIDv7: ids ordered by creation, so a new row lands at the end of its
      # primary key's index rather than anywhere in it. Ids a context sets
      # itself come from `Ryker.Repo.generate_id/0`, the same kind.
      @primary_key {:id, Ecto.UUID, autogenerate: [version: 7, precision: :monotonic]}
      @foreign_key_type :binary_id
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end

  @doc false
  def query do
    quote do
      import Ecto.Query
    end
  end

  @doc false
  def changeset do
    quote do
      import Ecto.Changeset
    end
  end

  defmacro __using__(role) when role in [:schema, :query, :changeset] do
    apply(__MODULE__, role, [])
  end
end
