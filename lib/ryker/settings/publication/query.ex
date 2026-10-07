defmodule Ryker.Settings.Publication.Query do
  @moduledoc "How Work publishes changes, for every read of `publication_settings`."
  use Ryker, :query
  alias Ryker.Settings.Publication

  def all, do: from(rows in Publication, as: :publication_settings)

  def by_id(queryable \\ all(), id), do: where(queryable, [publication_settings: p], p.id == ^id)
end
