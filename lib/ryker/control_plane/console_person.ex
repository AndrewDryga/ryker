defmodule Ryker.ControlPlane.ConsolePerson do
  @moduledoc "A person a console sign-in named, by login (`Ryker.ControlPlane.ConsolePeople`)."
  use Ecto.Schema

  @primary_key {:login, :string, autogenerate: false}
  schema "control_plane_people" do
    field(:name, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
