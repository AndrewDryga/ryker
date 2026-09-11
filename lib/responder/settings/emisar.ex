defmodule Responder.Settings.Emisar do
  @moduledoc "Emisar approval monitoring desired state."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  @fields ~w(enabled)a

  schema "emisar_settings" do
    field(:enabled, :boolean, default: false)
  end

  def fields, do: @fields

  def changeset(current, attributes, _snapshot) do
    current |> cast(attributes, @fields) |> validate_required(@fields)
  end
end
