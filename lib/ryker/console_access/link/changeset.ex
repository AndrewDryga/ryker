defmodule Ryker.ConsoleAccess.Link.Changeset do
  @moduledoc "How a console sign-in link is made and used (`Ryker.ConsoleAccess.Link`)."
  use Ryker, :changeset
  alias Ryker.ConsoleAccess.Link

  @fields [
    :created_by,
    :expires_at,
    :person_login,
    :person_name,
    :person_via,
    :purpose,
    :return_to,
    :token_sha256
  ]
  @required @fields -- [:return_to]

  @doc """
  A new link made at `at`, kept as the digest of its token. `at` is the database's clock, which
  also stamps its use, and its check holds the two in order.
  """
  def insert(attributes, at) do
    %Link{}
    |> cast(attributes, @fields)
    |> validate_required(@required)
    |> put_change(:inserted_at, at)
    |> put_change(:updated_at, at)
    |> validate_length(:person_name, min: 1, max: 120, count: :codepoints)
    |> unique_constraint(:token_sha256)
    |> check_constraint(:person_via, name: :console_sign_in_link_valid)
  end

  @doc "The link is spent: it signed its person in."
  def redeem(%Link{} = link, at) do
    link
    |> change(used_at: at)
    |> check_constraint(:used_at, name: :console_sign_in_link_valid)
  end
end
