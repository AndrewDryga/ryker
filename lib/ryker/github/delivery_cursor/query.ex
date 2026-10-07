defmodule Ryker.GitHub.DeliveryCursor.Query do
  @moduledoc "Where the GitHub delivery poller stopped, for every read of `github_delivery_cursors`."
  use Ryker, :query
  alias Ryker.GitHub.DeliveryCursor

  def all, do: from(cursors in DeliveryCursor, as: :github_delivery_cursors)

  def by_app_id(queryable \\ all(), app_id),
    do: where(queryable, [github_delivery_cursors: c], c.app_id == ^app_id)

  def select_through_delivery_id(queryable \\ all()),
    do: select(queryable, [github_delivery_cursors: c], c.through_delivery_id)
end
