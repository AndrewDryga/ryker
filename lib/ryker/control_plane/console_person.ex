defmodule Ryker.ControlPlane.ConsolePerson do
  @moduledoc "A person a console sign-in named, by login (`Ryker.ControlPlane.ConsolePeople`)."
  use Ryker, :schema

  @primary_key {:login, :string, autogenerate: false}
  schema "control_plane_people" do
    field(:name, :string)
    timestamps()
  end
end
