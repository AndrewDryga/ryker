defmodule Ryker.Credential.Event do
  @moduledoc false
  use Ryker, :schema

  schema "integration_credential_events" do
    field(:credential_id, :binary_id)

    field(:kind, Ecto.Enum,
      values: [:slack_app, :slack_bot, :github_private_key, :github_webhook, :emisar, :webhook]
    )

    field(:name, :string)
    field(:action, Ecto.Enum, values: [:created, :replaced, :verified, :invalidated, :deleted])
    field(:actor_ref, :string)
    field(:fingerprint, :string)
    field(:inserted_at, :utc_datetime_usec)
  end
end
