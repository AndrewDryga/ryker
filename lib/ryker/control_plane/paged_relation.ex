defmodule Ryker.ControlPlane.PagedRelation do
  @moduledoc """
  One bounded, exactly counted page of a repeating relation.

  A fixed `limit` with no total let a truncated relationship look complete or
  empty. Every collection read through here reports its exact filtered total,
  a normalized page and the page count, so a reader can always tell "nothing
  here" from "not on this page".
  """

  import Ecto.Query

  alias Ryker.Repo

  @page_size 25
  @maximum_page 10_000

  @type t :: %{
          key: String.t(),
          items: [term()],
          total: non_neg_integer(),
          page: pos_integer(),
          pages: pos_integer()
        }

  @spec page_size() :: pos_integer()
  def page_size, do: @page_size

  @doc """
  Normalizes one namespaced page parameter.

  Non-scalar, non-numeric, zero and negative values are page one; pages past
  the end are clamped to the last page when the relation is read.
  """
  @spec requested(map(), String.t()) :: pos_integer()
  def requested(params, key) when is_map(params) do
    case Map.get(params, key) do
      value when is_binary(value) and byte_size(value) <= 16 ->
        case Integer.parse(value) do
          {page, ""} when page >= 1 -> min(page, @maximum_page)
          _ -> 1
        end

      _ ->
        1
    end
  end

  def requested(_params, _key), do: 1

  @doc """
  Reads the requested page of `query` in `order`.

  `query` must be unordered and unlimited: the total is counted from it, and
  `order` must end in a unique column so timestamp ties never duplicate or
  skip a row between pages.
  """
  @spec read(Ecto.Query.t(), keyword(), String.t(), pos_integer(), keyword()) :: t()
  def read(query, order, key, requested_page, options \\ []) do
    page_size = Keyword.get(options, :page_size, @page_size)
    total = Repo.aggregate(query, :count)
    pages = max(div(total + page_size - 1, page_size), 1)
    page = min(requested_page, pages)

    items =
      Repo.all(
        from(row in query,
          order_by: ^order,
          limit: ^page_size,
          offset: ^((page - 1) * page_size)
        )
      )

    %{key: key, items: items, total: total, page: page, pages: pages}
  end
end
