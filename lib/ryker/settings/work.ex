defmodule Ryker.Settings.Work do
  @moduledoc "Which enrolled worker workspace runs Work; a browser never invents one."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @fields ~w(workspace_ref)a

  schema "work_settings" do
    field(:workspace_ref, :string)
  end

  def fields, do: @fields

  def changeset(current, attributes, _snapshot) do
    current
    |> cast(attributes, @fields)
    |> validate_length(:workspace_ref, min: 1, max: 256)
  end
end
