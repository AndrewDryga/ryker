defmodule Ryker.ConsoleAccess.Link do
  @moduledoc """
  A link that signs one person in to the console once (`Ryker.ConsoleAccess`): an operator's
  from Slack, the host owner's, or an invite for someone outside Slack. It keeps the SHA-256 of
  its token, never the token, and the page it returns to.
  """
  use Ryker, :schema

  schema "console_sign_in_links" do
    field(:token_sha256, :string)
    field(:purpose, Ecto.Enum, values: [:sign_in, :invite])
    field(:person_via, Ecto.Enum, values: [:slack_operator, :invite, :owner])
    field(:person_login, :string)
    field(:person_name, :string)
    field(:created_by, :string)
    field(:return_to, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:used_at, :utc_datetime_usec)

    timestamps()
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          token_sha256: String.t() | nil,
          purpose: :sign_in | :invite | nil,
          person_via: :slack_operator | :invite | :owner | nil,
          person_login: String.t() | nil,
          person_name: String.t() | nil,
          created_by: String.t() | nil,
          return_to: String.t() | nil,
          expires_at: DateTime.t() | nil,
          used_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }
end
