defmodule Ryker.GitHub.Payload do
  @moduledoc """
  A GitHub webhook payload cut to fit the input it becomes.

  GitHub attaches every repository, user and app object's API links, about
  forty to a repository, and no reader follows them. A comment also carries
  the whole pull request it was left on, description included. Past 40,000
  bytes the router refused such a delivery for good, so a comment on a pull
  request with a long description never reached Ryker (2026-10-04 review).
  The API links go first; then the longest text is cut until the payload
  fits. The same payload is always cut the same way.
  """

  alias Ryker.{CanonicalJSON, Text}

  @api "https://api.github.com/"
  # Text this short is left whole; a payload that still does not fit is refused.
  @shortest_cut 1_024

  @spec fit(map(), pos_integer()) :: {:ok, map()} | {:error, :too_large}
  def fit(payload, budget) when is_map(payload) and is_integer(budget) and budget > 0,
    do: payload |> without_api_links() |> cut_to(budget)

  defp without_api_links(%{} = map) do
    for {key, value} <- map, not api_link?(key, value), into: %{} do
      {key, without_api_links(value)}
    end
  end

  defp without_api_links(list) when is_list(list), do: Enum.map(list, &without_api_links/1)
  defp without_api_links(value), do: value

  defp api_link?(key, value) when is_binary(key) and is_binary(value),
    do: (key == "url" or String.ends_with?(key, "_url")) and String.starts_with?(value, @api)

  defp api_link?(_key, _value), do: false

  # Each pass cuts the longest text by what is still too much, so a text's
  # escaped size only costs another pass.
  defp cut_to(payload, budget) do
    excess = byte_size(CanonicalJSON.encode!(payload)) - budget

    case excess > 0 and longest_text(payload, [], nil) do
      false ->
        {:ok, payload}

      {path, text} when byte_size(text) > @shortest_cut ->
        keep = max(@shortest_cut, byte_size(text) - excess)
        payload |> put_in(path, Text.cut(text, keep)) |> cut_to(budget)

      _all_short ->
        {:error, :too_large}
    end
  end

  defp longest_text(%{} = map, path, longest) do
    map
    |> Enum.sort()
    |> Enum.reduce(longest, fn {key, value}, longest ->
      longest_text(value, path ++ [Access.key(key)], longest)
    end)
  end

  defp longest_text(list, path, longest) when is_list(list) do
    list
    |> Enum.with_index()
    |> Enum.reduce(longest, fn {value, index}, longest ->
      longest_text(value, path ++ [Access.at(index)], longest)
    end)
  end

  defp longest_text(text, path, {_path, longest_text} = longest) when is_binary(text),
    do: if(byte_size(text) > byte_size(longest_text), do: {path, text}, else: longest)

  defp longest_text(text, path, nil) when is_binary(text), do: {path, text}
  defp longest_text(_value, _path, longest), do: longest
end
