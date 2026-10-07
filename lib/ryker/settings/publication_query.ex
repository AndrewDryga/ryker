defmodule Ryker.Settings.PublicationQuery do
  @moduledoc "How Work publishes changes, for every read of `publication_settings`."
  import Ecto.Query
  alias Ryker.Settings.Publication

  def all, do: from(rows in Publication, as: :publication_settings)

  def by_id(queryable \\ all(), id), do: where(queryable, [publication_settings: p], p.id == ^id)
end
