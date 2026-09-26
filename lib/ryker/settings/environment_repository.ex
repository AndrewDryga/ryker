defmodule Ryker.Settings.EnvironmentRepository do
  @moduledoc """
  One repository of an environment and its place in the order.

  Position 0 is the default choice of the repository work changes. Every
  session in the environment mounts all of its repositories: the one its work
  changes as the working copy and each other one read-only under its own ref.
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
