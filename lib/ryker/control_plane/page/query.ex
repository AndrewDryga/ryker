defmodule Ryker.ControlPlane.Page.Query do
  @moduledoc "One page of any relation, for `Ryker.ControlPlane.PagedRelation`."
  import Ecto.Query

  @doc "The `size` rows of `query` in `order` after the first `offset`."
  def page(queryable, order, size, offset),
    do: from(row in queryable, order_by: ^order, limit: ^size, offset: ^offset)
end
