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
    # Whether routing decisions are copied into the training set
    # (`Ryker.RoutingExamples`), and how long each copy is kept.
    field(:routing_examples_enabled, :boolean, default: false)
    field(:routing_examples_seconds, :integer)
  end
end
