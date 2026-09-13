defmodule Ryker.GitHub.SourceRef do
  @moduledoc false

  @binding ~r/\A[a-z][a-z0-9_-]{0,63}\z/
  @kinds ~w(issue_comment pull_request_review_comment)

  @spec item(String.t(), String.t(), pos_integer()) :: String.t()
  def item(binding, kind, id) do
    if binding?(binding) and kind in @kinds and is_integer(id) and id > 0 do
      "github-source:v1:#{binding}:#{kind}:#{id}"
    else
      raise ArgumentError, "invalid GitHub source identity"
    end
  end

  @spec parse(String.t()) :: {:ok, map()} | {:error, :invalid_github_source_ref}
  def parse(value) when is_binary(value) do
    case String.split(value, ":") do
      ["github-source", "v1", binding, kind, id] when kind in @kinds ->
        parse_item(binding, kind, id)

      _invalid ->
        {:error, :invalid_github_source_ref}
    end
  end

  def parse(_value), do: {:error, :invalid_github_source_ref}

  defp parse_item(binding, kind, value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 and id <= 9_223_372_036_854_775_807 ->
        parsed_item(binding, kind, id)

      _invalid ->
        {:error, :invalid_github_source_ref}
    end
  end

  defp parsed_item(binding, kind, id) do
    if binding?(binding),
      do: {:ok, %{binding: binding, item_id: id, item_kind: kind}},
      else: {:error, :invalid_github_source_ref}
  end

  defp binding?(value), do: is_binary(value) and Regex.match?(@binding, value)
end
