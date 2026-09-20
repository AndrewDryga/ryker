defmodule Ryker.GitHub.Event do
  @moduledoc "Durable receipt and disposition for one authenticated GitHub delivery."

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}

  schema "github_repository_events" do
    field(:delivery_ref, :string)
    field(:binding_ref, :string)
    field(:repository_id, :integer)
    field(:event_name, :string)
    field(:action, :string)
    field(:event_ref, :string)
    field(:payload_digest, :string)
    field(:disposition, :string)
    field(:reason, :string)
    field(:occurred_at, :utc_datetime_usec)
    field(:processed_at, :utc_datetime_usec)
    field(:duplicate_count, :integer, default: 0)
    field(:last_duplicate_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
