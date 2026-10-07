defmodule Ryker.Credential.Query do
  @moduledoc "Saved integration credentials, for every read of `integration_credentials`."
  import Ecto.Query
  alias Ryker.Credential

  def all, do: from(credentials in Credential, as: :integration_credentials)

  def by_identity(queryable \\ all(), kind, name) do
    where(
      queryable,
      [integration_credentials: c],
      c.kind == ^kind and c.name == ^name
    )
  end

  def ordered_by_identity(queryable),
    do: order_by(queryable, [integration_credentials: c], asc: c.kind, asc: c.name)
end
