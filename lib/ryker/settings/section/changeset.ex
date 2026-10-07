defmodule Ryker.Settings.Section.Changeset do
  @moduledoc """
  What the settings write path (`Ryker.Settings`) asks of the changeset
  module of each kind of setting: the fields a save may name, and the
  changeset that adds an item or changes a saved one. Each sees the snapshot
  the save started from, since one setting can depend on another, as an
  environment does on the repositories it names.
  """
  use Ryker, :changeset

  @doc "The fields a save may name; a save that names any other is refused."
  @callback fields() :: [atom()]

  @doc "A new item of a list of settings, such as a repository."
  @callback insert(attributes :: map(), snapshot :: Ryker.Settings.snapshot()) ::
              Ecto.Changeset.t()

  @doc "A change to a saved setting or item."
  @callback update(
              current :: struct(),
              attributes :: map(),
              snapshot :: Ryker.Settings.snapshot()
            ) :: Ecto.Changeset.t()

  @optional_callbacks insert: 2
end
