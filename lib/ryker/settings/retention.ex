defmodule Ryker.Settings.Retention do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}

  schema "retention_settings" do
    field(:operational_data_seconds, :integer)
    field(:conversation_memory_seconds, :integer)
    field(:closed_work_seconds, :integer)
    field(:episode_history_seconds, :integer)
    field(:audit_data_seconds, :integer)
  end
end
