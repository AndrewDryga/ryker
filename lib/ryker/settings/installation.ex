defmodule Ryker.Settings.Installation do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:host_ref, :string, autogenerate: false}

  schema "installation_settings" do
    field(:singleton, :boolean, default: true)
    field(:revision, :integer)
    field(:applied_revision, :integer, default: 0)
    field(:failure_code, :string)
    field(:saved_by, :string)
    field(:saved_at, :utc_datetime_usec)
    field(:inserted_at, :utc_datetime_usec)
  end
end
