defmodule Ryker.ConsoleAccess.Session do
  @moduledoc """
  One browser a link signed in to the console (`Ryker.ConsoleAccess`): who it is, until when,
  and when it was last used. It keeps the SHA-256 of the token its cookie holds.
  """
  use Ryker, :schema

  schema "console_sessions" do
    field(:token_sha256, :string)
    field(:person_via, Ecto.Enum, values: [:slack_operator, :invite, :owner])
    field(:person_login, :string)
    field(:person_name, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:last_seen_at, :utc_datetime_usec)

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          token_sha256: String.t() | nil,
          person_via: :slack_operator | :invite | :owner | nil,
          person_login: String.t() | nil,
          person_name: String.t() | nil,
          expires_at: DateTime.t() | nil,
          last_seen_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }
end
