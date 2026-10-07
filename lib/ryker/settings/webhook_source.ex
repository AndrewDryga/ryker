defmodule Ryker.Settings.WebhookSource do
  @moduledoc "One inbound webhook source: preset or custom mapping, auth, destination and environment."
  use Ecto.Schema

  @primary_key {:name, :string, autogenerate: false}

  schema "webhook_source_settings" do
    field(:enabled, :boolean, default: true)
    field(:adapter_kind, Ecto.Enum, values: [:universal, :grafana, :mapped_json])
    field(:auth_kind, Ecto.Enum, values: [:bearer, :hmac_sha256])
    field(:secret_name, :string)
    field(:destination_transport, :string)
    field(:destination_conversation_ref, :string)
    field(:destination_thread_ref, :string)
    field(:environment_ref, :string)
    field(:group_by_labels, {:array, :string}, default: [])
    field(:mapping, :map)
    field(:publication_lifecycle, :map)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}
end
