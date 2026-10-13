defmodule Ryker.ConsoleAccess.Session.Changeset do
  @moduledoc "How a signed-in console browser is recorded (`Ryker.ConsoleAccess.Session`)."
  use Ryker, :changeset
  alias Ryker.ConsoleAccess.Session

  @fields [:expires_at, :last_seen_at, :person_login, :person_name, :person_via, :token_sha256]

  @doc "A browser a link signed in at `at`, kept as the digest of its cookie's token."
  def insert(attributes, at) do
    %Session{}
    |> cast(attributes, @fields)
    |> validate_required(@fields)
    |> put_change(:inserted_at, at)
    |> put_change(:updated_at, at)
    |> unique_constraint(:token_sha256)
    |> check_constraint(:person_via, name: :console_session_valid)
  end
end
