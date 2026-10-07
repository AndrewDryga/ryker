defmodule Ryker.Settings.Publication do
  @moduledoc "Draft publication settings; credentials alone never enable publishing."
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "publication_settings" do
    field(:enabled, :boolean, default: false)
    field(:branch_prefix, :string, default: "ryker")
  end

  @type t :: %__MODULE__{}
end
