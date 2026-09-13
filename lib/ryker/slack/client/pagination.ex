defmodule Ryker.Slack.Client.Pagination do
  @moduledoc """
  Walks a cursor-paged Slack listing.

  Every listing the client walks has the same shape: a path that takes the
  cursor, a page reader that yields the page's items and the next cursor, and
  either something to find on a page or everything to collect. The walk is
  bounded, and running out of pages before an answer is a reconciliation the
  caller must not mistake for "not there".
  """

  alias Ryker.Slack.Client
  alias Ryker.Slack.Client.Transport

  @maximum_pages 100

  @type path :: (String.t() | nil -> String.t())
  @type page :: (map() -> {:ok, [term()], String.t()} | {:error, term()})

  @doc """
  Fetches pages until `match` finds a value or the cursor runs out.

  `page_size` sizes the message when the bound is hit, so the caller can say
  how many items were searched.
  """
  @spec find(
          Client.t(),
          path(),
          page(),
          ([term()] -> {:ok, term()} | :not_found | {:error, term()}),
          pos_integer()
        ) ::
          {:ok, term()} | :not_found | {:error, term()}
  def find(client, path, page, match, page_size),
    do: find(client, path, page, match, page_size, nil, 1)

  defp find(client, path, page, match, page_size, cursor, number) do
    with {:ok, items, next_cursor} <- fetch(client, path, page, cursor) do
      case match.(items) do
        {:ok, value} ->
          {:ok, value}

        :not_found when next_cursor == "" ->
          :not_found

        :not_found when number < @maximum_pages ->
          find(client, path, page, match, page_size, next_cursor, number + 1)

        :not_found ->
          incomplete(page_size)

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc "Fetches every page and returns the items in order."
  @spec collect(Client.t(), path(), page(), pos_integer()) :: {:ok, [term()]} | {:error, term()}
  def collect(client, path, page, page_size),
    do: collect(client, path, page, page_size, nil, 1, [])

  defp collect(client, path, page, page_size, cursor, number, items) do
    with {:ok, page_items, next_cursor} <- fetch(client, path, page, cursor) do
      items = items ++ page_items

      cond do
        next_cursor == "" ->
          {:ok, items}

        number < @maximum_pages ->
          collect(client, path, page, page_size, next_cursor, number + 1, items)

        true ->
          incomplete(page_size)
      end
    end
  end

  defp fetch(client, path, page, cursor) do
    with {:ok, response} <- Transport.request(client, :get, path.(cursor), nil),
         {:ok, body} <- Transport.response(response) do
      page.(body)
    end
  end

  defp incomplete(page_size),
    do: {:error, {:slack_reconciliation_incomplete, @maximum_pages * page_size}}

  @doc "The next cursor of a listing body: `\"\"` when Slack sent none, an error when it sent junk."
  @spec next_cursor(map()) :: {:ok, String.t()} | {:error, :cursor}
  def next_cursor(body) do
    case get_in(body, ["response_metadata", "next_cursor"]) do
      nil -> {:ok, ""}
      cursor when is_binary(cursor) -> {:ok, cursor}
      _invalid -> {:error, :cursor}
    end
  end

  @doc "A listing path with its query, and the cursor when there is one."
  @spec query(String.t(), [{String.t(), term()}], String.t() | nil) :: String.t()
  def query(path, parameters, nil), do: path <> "?" <> URI.encode_query(parameters)

  def query(path, parameters, cursor),
    do: path <> "?" <> URI.encode_query(parameters ++ [{"cursor", cursor}])
end
