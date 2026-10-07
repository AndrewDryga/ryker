defmodule Ryker.Settings.Learning do
  @moduledoc "Model-based background learning choice, separate from deterministic compaction."
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "learning_settings" do
    field(:enabled, :boolean, default: true)
  end

  @type t :: %__MODULE__{}
end
