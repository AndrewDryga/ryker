defmodule Ryker.Settings.Learning do
  @moduledoc "Model-based background learning choice, separate from deterministic compaction."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @fields ~w(enabled)a

  schema "learning_settings" do
    field(:enabled, :boolean, default: true)
  end

  def fields, do: @fields

  def changeset(current, attributes, _snapshot) do
    current |> cast(attributes, @fields) |> validate_required(@fields)
  end
end
