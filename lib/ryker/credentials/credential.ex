defmodule Ryker.Credentials.Credential do
  @moduledoc false
  use Ecto.Schema

  @derive {Inspect, except: [:ciphertext, :nonce, :tag]}
  @primary_key {:id, :binary_id, autogenerate: false}

  schema "integration_credentials" do
    field(:kind, Ecto.Enum,
      values: [:slack_app, :slack_bot, :github_private_key, :github_webhook, :emisar, :webhook]
    )

    field(:name, :string)
    field(:key_version, :integer)
    field(:ciphertext, :binary, redact: true)
    field(:nonce, :binary, redact: true)
    field(:tag, :binary, redact: true)
    field(:fingerprint, :string)
    field(:verification_status, Ecto.Enum, values: [:unverified, :verified, :invalid])
    field(:verified_at, :utc_datetime_usec)
    field(:inserted_at, :utc_datetime_usec)
    field(:updated_at, :utc_datetime_usec)
  end
end
