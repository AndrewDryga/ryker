defmodule Ryker.Settings.EnvironmentRepository do
  @moduledoc """
  One repository of an environment and its place in the order.

  Position 0 is the repository work in the environment changes; every other
  position is mounted read-only under the repository's own ref.
  """
  use Ecto.Schema

  @primary_key false

  @type t :: %__MODULE__{
          environment_ref: String.t(),
          repository_ref: String.t(),
          position: non_neg_integer()
        }

  schema "environment_repository_settings" do
    field(:environment_ref, :string, primary_key: true)
    field(:repository_ref, :string, primary_key: true)
    field(:position, :integer)
  end
end
